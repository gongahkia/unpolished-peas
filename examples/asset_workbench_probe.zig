//! The same portable game and scripted input run natively and in freestanding
//! Wasm. The Node check compares the resulting pixels and explicit save bytes.
const std = @import("std");
const up = @import("unpolished-peas");
const game = @import("asset_workbench_game.zig");
const Result = struct { hash: u64 = 0, score: u32 = 0, saved: u32 = 0 };
var result: Result = .{};

fn probe(allocator: std.mem.Allocator) !Result {
    const runner = try up.testSupport.HeadlessGameRunner(game.Game).initSeeded(allocator, game.width, game.height, 42);
    defer runner.deinit();
    for (0..12) |tick| {
        var input = up.input.Input{};
        input.set(.right, true);
        input.set(.action, tick == 0 or tick == 6);
        try runner.step(input.snapshot(), 1.0 / 60.0);
    }
    try runner.draw(0);
    var bytes: [4]u8 = undefined;
    const saved = try runner.save_data.read("recipe-progress", &bytes);
    if (saved.len != 4) return error.InvalidSavedProgress;
    return .{ .hash = runner.capture().image_hash, .score = runner.game.score, .saved = std.mem.readInt(u32, &bytes, .little) };
}

pub export fn asset_run() u32 {
    result = probe(std.heap.page_allocator) catch return 1;
    return 0;
}
pub export fn asset_hash() u64 {
    return result.hash;
}
pub export fn asset_score() u32 {
    return result.score;
}
pub export fn asset_saved() u32 {
    return result.saved;
}

pub fn main() !void {
    if (comptime @import("builtin").os.tag == .freestanding) return;
    result = try probe(std.heap.page_allocator);
    var bytes: [160]u8 = undefined;
    const json = try std.fmt.bufPrint(&bytes, "{{\"hash\":\"{d}\",\"score\":{d},\"saved\":{d}}}\n", .{ result.hash, result.score, result.saved });
    try std.fs.File.stdout().writeAll(json);
}
