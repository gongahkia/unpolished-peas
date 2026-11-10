//! Developer-only bridge from the public replay format to the existing browser
//! input wire ABI v2. No input/replay code is added to production bundles.
const std = @import("std");
const up = @import("unpolished-peas");
const game = @import("game.zig");
const wire_bytes = 1890;
fn mask(values: []const bool) u32 {
    var result: u32 = 0;
    for (values, 0..) |v, i| if (v) {
        result |= @as(u32, 1) << @intCast(i);
    };
    return result;
}
fn put(b: []u8, index: usize, value: u32) void {
    std.mem.writeInt(u32, b[index..][0..4], value, .little);
}
fn float(b: []u8, index: usize, value: f32) void {
    put(b, index, @bitCast(value));
}
fn encode(frame: up.input.Input.Snapshot, b: []u8) !void {
    @memset(b, 0);
    put(b, 0, 2);
    put(b, 4, 3 | (if (frame.pointer.canvas != null) @as(u32, 4) else 0));
    put(b, 12, game.width);
    put(b, 16, game.height);
    put(b, 20, mask(&frame.down));
    put(b, 24, mask(&frame.pressed));
    put(b, 28, mask(&frame.released));
    put(b, 32, mask(&frame.pointer_down));
    put(b, 36, mask(&frame.pointer_pressed));
    put(b, 40, mask(&frame.pointer_released));
    float(b, 44, frame.pointer.window.x);
    float(b, 48, frame.pointer.window.y);
    float(b, 52, frame.pointer.framebuffer.x);
    float(b, 56, frame.pointer.framebuffer.y);
    const p = frame.pointer.canvas orelse up.core.Vec2{};
    float(b, 60, p.x);
    float(b, 64, p.y);
    float(b, 68, frame.pointer.delta.x);
    float(b, 72, frame.pointer.delta.y);
    float(b, 76, frame.pointer.wheel.x);
    float(b, 80, frame.pointer.wheel.y);
    var count: usize = 0;
    for (frame.gamepads) |slot| if (slot) |pad| {
        const offset = 88 + count * 72;
        count += 1;
        put(b, offset, @bitCast(pad.id));
        put(b, offset + 4, @intFromBool(pad.connected));
        put(b, offset + 8, mask(&pad.buttons));
        put(b, offset + 12, mask(&pad.pressed));
        put(b, offset + 16, mask(&pad.released));
        for (pad.axes, 0..) |axis, i| float(b, offset + 20 + i * 4, axis);
        for (pad.previous_axes, 0..) |axis, i| float(b, offset + 44 + i * 4, axis);
    };
    put(b, 84, @intCast(count));
    const length = try frame.extended.encode(b[378..]);
    std.mem.writeInt(u16, b[376..378], @intCast(length), .little);
}
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
        try encode(frame, wire[index * wire_bytes ..][0..wire_bytes]);
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
    const json = try std.json.Stringify.valueAlloc(allocator, .{ .abi_version = 2, .frame_bytes = wire_bytes, .ticks = replay.frames.len, .width = game.width, .height = game.height, .milestones = marks.items, .continue_reference = "continued.rgba" }, .{});
    defer allocator.free(json);
    try std.fs.cwd().writeFile(.{ .sub_path = try std.fmt.bufPrint(&filename, "{s}/route.json", .{args[2]}), .data = json });
}
