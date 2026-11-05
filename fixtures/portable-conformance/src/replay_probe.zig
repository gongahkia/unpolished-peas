const std = @import("std");
const up = @import("unpolished-peas");
const game = @import("game.zig");
const scenario = @import("scenario.zig");
const Runner = up.testSupport.HeadlessGameRunner(game.Game);
const Result = struct { hash: u64 = 0, progress: [game.progress_size]u8 = .{0} ** game.progress_size };
var result: Result = .{};

fn run(allocator: std.mem.Allocator) !Result {
    var saves: up.testSupport.InMemorySaveStore = undefined;
    saves.init(allocator);
    defer saves.deinit();
    var initial = game.Game{ .score = 7 };
    @memcpy(initial.name[0..5], "Start");
    initial.name_len = 5;
    try saves.capability().write("progress", &initial.progress());
    const identity = up.preview.developer.InputReplay.Environment.Identity{ .game = "portable-conformance", .build = "1", .assets = "fixture-1" };
    var recorder = try up.preview.developer.InputReplayRecorder.initSession(allocator, 60, game.default_seed, .{
        .identity = identity,
        .save_data = saves.capability(),
        .save_keys = &.{"progress"},
    });
    defer recorder.deinit();
    const live = try Runner.initSeededWithSaveData(allocator, game.width, game.height, game.default_seed, saves.capability());
    defer live.deinit();
    for (0..scenario.ticks) |tick| {
        const input = try scenario.input(tick);
        try recorder.record(input);
        try live.step(input.snapshot(), 1.0 / 60.0);
    }
    try live.draw(0);
    var replay = try recorder.finish();
    defer replay.deinit(allocator);
    const bytes = try replay.encode(allocator);
    defer allocator.free(bytes);
    if (!std.mem.eql(u8, bytes[0..4], "UPR5")) return error.WrongReplayVersion;
    var parsed = try up.preview.developer.parseInputReplay(allocator, bytes);
    defer parsed.deinit(allocator);
    const reproduced = try Runner.initReplay(allocator, game.width, game.height, parsed, identity);
    defer reproduced.deinit();
    if (reproduced.game.score != 7) return error.InitialSaveNotRestored;
    try reproduced.runReplay(parsed);
    if (live.capture().image_hash != reproduced.capture().image_hash or
        try live.capture().canvas_trace.hash() != try reproduced.capture().canvas_trace.hash() or
        !std.mem.eql(u8, &live.game.progress(), &reproduced.game.progress())) return error.SessionReplayMismatch;
    return .{ .hash = live.capture().image_hash, .progress = live.game.progress() };
}

pub export fn replay_probe_run() u32 {
    result = run(std.heap.page_allocator) catch return 1;
    return 0;
}
pub export fn replay_probe_hash() u64 {
    return result.hash;
}
pub export fn replay_probe_progress() u32 {
    return @intCast(@intFromPtr(&result.progress));
}

pub fn main() !void {
    if (comptime @import("builtin").os.tag == .freestanding) return;
    const allocator = std.heap.page_allocator;
    result = try run(allocator);
    const hash = try std.fmt.allocPrint(allocator, "{d}", .{result.hash});
    defer allocator.free(hash);
    const json = try std.json.Stringify.valueAlloc(allocator, .{ .hash = hash, .progress = std.fmt.bytesToHex(result.progress, .lower) }, .{});
    defer allocator.free(json);
    try std.fs.File.stdout().writeAll(json);
}
