//! Developer-only bridge from the public replay format to the existing browser
//! input wire ABI v2. No input/replay code is added to production bundles.
const std = @import("std");
const up = @import("unpolished-peas");
const game = @import("game.zig");
const codec = up.preview.developer.BrowserInput;
const wire_bytes = codec.abi_bytes;
const Milestone = struct { label: []const u8, tick: usize };
pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 3) return error.ExpectedReplayAndOutputDirectory;
    const bytes = try std.fs.cwd().readFileAlloc(allocator, args[1], 16 * 1024 * 1024);
    defer allocator.free(bytes);
    var replay = try up.preview.developer.parseInputReplay(allocator, bytes);
    defer replay.deinit(allocator);
    if (replay.fixed_hz != 60) return error.ExpectedSixtyHzReplay;
    try std.fs.cwd().makePath(args[2]);
    const wire = try allocator.alloc(u8, replay.frames.len * wire_bytes);
    defer allocator.free(wire);
    const r = try up.testSupport.HeadlessGameRunner(game.Game).initSeeded(allocator, game.width, game.height, game.default_seed);
    defer r.deinit();
    var marks: std.ArrayList(Milestone) = .empty;
    defer marks.deinit(allocator);
    var captured = [_]bool{false} ** 5;
    for (replay.frames, 0..) |frame, index| {
        try codec.encode(frame, .{ .framebuffer_width = game.width, .framebuffer_height = game.height, .focused = true, .visible = true }, wire[index * wire_bytes ..][0..wire_bytes]);
        try r.step(frame, 1.0 / 60.0);
        var label: ?[]const u8 = null;
        if (r.game.state.room == 1 and !captured[0]) {
            label = "cloister";
            captured[0] = true;
        }
        for (r.game.state.enemies) |e| if (e.kind == .warden and e.hp > 0) {
            if (e.stage == .windup and !captured[1]) {
                label = "warden-windup";
                captured[1] = true;
            }
            if (e.stage == .transition and !captured[2]) {
                label = "warden-transition";
                captured[2] = true;
            }
        };
        for (r.game.state.rings) |ring| if (ring.alive and ring.age > 10 and !captured[3]) {
            label = "warden-shock";
            captured[3] = true;
        };
        if (r.game.state.completed and !captured[4]) {
            label = "victory";
            captured[4] = true;
        }
        if (label) |name| {
            try r.draw(0);
            try marks.append(allocator, .{ .label = name, .tick = index });
            var filename: [1024]u8 = undefined;
            try std.fs.cwd().writeFile(.{ .sub_path = try std.fmt.bufPrint(&filename, "{s}/{s}.rgba", .{ args[2], name }), .data = std.mem.sliceAsBytes(r.canvas.pixels) });
            try r.canvas.writePngFile(try std.fmt.bufPrint(&filename, "{s}/{s}.png", .{ args[2], name }));
        }
    }
    if (!r.game.state.completed) return error.ReplayDidNotWin;
    const continued = try up.testSupport.HeadlessGameRunner(game.Game).initSeededWithSaveData(allocator, game.width, game.height, game.default_seed, r.save_data);
    defer continued.deinit();
    try continued.step(replay.frames[0], 1.0 / 60.0);
    try continued.draw(0);
    var filename: [1024]u8 = undefined;
    try std.fs.cwd().writeFile(.{ .sub_path = try std.fmt.bufPrint(&filename, "{s}/continued.rgba", .{args[2]}), .data = std.mem.sliceAsBytes(continued.canvas.pixels) });
    try continued.canvas.writePngFile(try std.fmt.bufPrint(&filename, "{s}/continued.png", .{args[2]}));
    try std.fs.cwd().writeFile(.{ .sub_path = try std.fmt.bufPrint(&filename, "{s}/frames.bin", .{args[2]}), .data = wire });
    const json = try std.json.Stringify.valueAlloc(allocator, .{ .abi_version = codec.encode_version, .frame_bytes = wire_bytes, .ticks = replay.frames.len, .width = game.width, .height = game.height, .milestones = marks.items, .continue_reference = "continued.rgba" }, .{});
    defer allocator.free(json);
    try std.fs.cwd().writeFile(.{ .sub_path = try std.fmt.bufPrint(&filename, "{s}/route.json", .{args[2]}), .data = json });
}
