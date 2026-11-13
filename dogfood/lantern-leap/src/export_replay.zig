//! Optional verification exporter. Gameplay input comes only from the ordinary route pilot.
const std = @import("std");
const up = @import("unpolished-peas");
const game = @import("game.zig");
const route = @import("route.zig");
const codec = up.preview.developer.BrowserInput;
const Runner = up.testSupport.HeadlessGameRunner(game.Game);
const Mark = struct { label: []const u8, tick: usize };
const allocator = std.heap.page_allocator;
var directory: []const u8 = undefined;
fn write(name: []const u8, bytes: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ directory, name });
    defer allocator.free(path);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = bytes });
}
fn capture(r: *Runner, name: []const u8) !void {
    try r.draw(0);
    const raw = try std.fmt.allocPrint(allocator, "{s}.rgba", .{name});
    defer allocator.free(raw);
    try write(raw, std.mem.sliceAsBytes(r.canvas.pixels));
    const png = try std.fmt.allocPrint(allocator, "{s}/{s}.png", .{ directory, name });
    defer allocator.free(png);
    try r.canvas.writePngFile(png);
}
fn reloadReference(store: *up.core.SaveStore, name: []const u8) !void {
    const r = try Runner.initSeededWithSaveData(allocator, game.width, game.height, game.default_seed, store);
    defer r.deinit();
    var input = up.input.Input{};
    try r.step(input.snapshot(), 1.0 / 60.0);
    try capture(r, name);
}
pub fn main() !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 2 or args.len > 3) return error.ExpectedOutputDirectoryAndOptionalMode;
    directory = args[1];
    try std.fs.cwd().makePath(directory);
    const mode: route.Mode = if (args.len == 3) std.meta.stringToEnum(route.Mode, args[2]) orelse return error.BadMode else .keyboard;
    var replay = try route.record(allocator, mode);
    defer replay.deinit(allocator);
    const upr = try replay.encode(allocator);
    defer allocator.free(upr);
    try write("route.upr", upr);
    const wire = try allocator.alloc(u8, replay.frames.len * codec.abi_bytes);
    defer allocator.free(wire);
    const r = try Runner.initSeeded(allocator, game.width, game.height, game.default_seed);
    defer r.deinit();
    var marks: std.ArrayList(Mark) = .empty;
    defer marks.deinit(allocator);
    var captured = [_]bool{false} ** 7;
    var pcm: [800]up.assets.AudioSample = undefined;
    for (replay.frames, 0..) |snapshot, index| {
        try codec.encode(snapshot, .{ .framebuffer_width = game.width, .framebuffer_height = game.height, .focused = true, .visible = true }, wire[index * codec.abi_bytes ..][0..codec.abi_bytes]);
        try r.step(snapshot, 1.0 / 60.0);
        try r.audio.mix(&pcm);
        const conditions = [_]bool{ r.game.screen == .playing, r.game.collected[0], r.game.screen == .paused, r.game.checkpoint == 1, r.game.dead, r.game.collectedCount() == 6, r.game.completed };
        const names = [_][]const u8{ "start", "first-glow", "paused", "checkpoint", "death", "six-glows", "complete" };
        for (conditions, 0..) |condition, i| if (condition and !captured[i]) {
            captured[i] = true;
            try capture(r, names[i]);
            try marks.append(allocator, .{ .label = names[i], .tick = index });
            if (i == 4) {
                var bytes: [16]u8 = undefined;
                try write("checkpoint-save.bin", try r.save_data.read("progress.v2", &bytes));
                try reloadReference(r.save_data, "checkpoint-reloaded");
            }
        };
    }
    for (captured) |done| if (!done) return error.MissingMilestone;
    try capture(r, "final");
    try marks.append(allocator, .{ .label = "final", .tick = replay.frames.len - 1 });
    var save: [16]u8 = undefined;
    try write("final-save.bin", try r.save_data.read("progress.v2", &save));
    try reloadReference(r.save_data, "reloaded");
    try write("frames.bin", wire);
    // Reload begins with an independent empty frame, rather than replaying Start.
    var empty = up.input.Input{};
    var reload_wire: [codec.abi_bytes]u8 = undefined;
    try codec.encode(empty.snapshot(), .{ .framebuffer_width = game.width, .framebuffer_height = game.height, .focused = true, .visible = true }, &reload_wire);
    try write("reload.bin", &reload_wire);
    const json = try std.json.Stringify.valueAlloc(allocator, .{ .game = "lantern-leap", .mode = @tagName(mode), .seed = game.default_seed, .abi_version = codec.encode_version, .frame_bytes = codec.abi_bytes, .ticks = replay.frames.len, .width = game.width, .height = game.height, .save_key = "progress.v2", .milestones = marks.items, .checkpoint_reference = true }, .{});
    defer allocator.free(json);
    try write("route.json", json);
}
