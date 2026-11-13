const std = @import("std");
const up = @import("unpolished-peas");
const game = @import("input-workbench-game");
const browser = @import("browser/input_snapshot.zig");
const TickBuffer = @import("frame-timing").TickBuffer;
const Runner = up.testSupport.HeadlessGameRunner(game.Game);
var runner: ?*Runner = null;
var pending = TickBuffer{};
var bytes: [browser.abi_bytes]u8 = undefined;
var recorder: up.preview.developer.InputReplayRecorder = undefined;

pub export fn input_init() u32 {
    runner = Runner.initSeeded(std.heap.page_allocator, game.width, game.height, 42) catch return 1;
    recorder = up.preview.developer.InputReplayRecorder.initSeeded(std.heap.page_allocator, 60, 42) catch return 2;
    return 0;
}
pub export fn input_destination() usize {
    return @intFromPtr(&bytes);
}
pub export fn input_text_requested() u32 {
    return @intFromBool(runner.?.text_input.enabled);
}
pub export fn input_submit(length: u32) u32 {
    if (length > bytes.len) return 1;
    const snapshot = browser.decode(bytes[0..length]) catch return 2;
    var state = up.input.Input{};
    snapshot.apply(&state);
    pending.submit(state);
    return 0;
}
pub export fn input_tick() u32 {
    const snapshot = pending.next();
    var state = up.input.Input{};
    snapshot.apply(&state);
    recorder.record(state) catch return 1;
    runner.?.step(snapshot, 1.0 / 60.0) catch return 2;
    runner.?.draw(0) catch return 3;
    return 0;
}
pub export fn input_x() i32 {
    return runner.?.game.x;
}
pub export fn input_one() u32 {
    return runner.?.game.one;
}
pub export fn input_two() u32 {
    return runner.?.game.two;
}
pub export fn input_name() usize {
    return @intFromPtr(&runner.?.game.name);
}
pub export fn input_name_length() usize {
    return runner.?.game.name_len;
}
pub export fn input_preedit_length() usize {
    return runner.?.game.preedit_len;
}
pub export fn input_round_trip() u32 {
    roundTrip() catch return 1;
    return 0;
}
fn roundTrip() !void {
    const allocator = std.heap.page_allocator;
    var replay = try recorder.finish();
    defer replay.deinit(allocator);
    const encoded = try replay.encode(allocator);
    defer allocator.free(encoded);
    var parsed = try up.preview.developer.parseInputReplay(allocator, encoded);
    defer parsed.deinit(allocator);
    var second = try Runner.initSeeded(allocator, game.width, game.height, 42);
    defer second.deinit();
    try second.runReplay(parsed);
    if (second.game.x != runner.?.game.x or second.game.one != runner.?.game.one or second.game.two != runner.?.game.two or
        !std.mem.eql(u8, second.game.name[0..second.game.name_len], runner.?.game.name[0..runner.?.game.name_len]) or
        second.capture().image_hash != runner.?.capture().image_hash) return error.ReplayDiverged;
}
pub export fn input_deinit() void {
    recorder.deinit();
    runner.?.deinit();
    runner = null;
}

// Cross-check against frames produced independently by the existing DOM encoder.
pub export fn input_reencode(length: u32) u32 {
    if (length != bytes.len) return 1;
    const snapshot = browser.decode(&bytes) catch return 2;
    const codec = up.preview.developer.BrowserInput;
    codec.encode(snapshot, .{
        .framebuffer_width = std.mem.readInt(u32, bytes[12..16], .little),
        .framebuffer_height = std.mem.readInt(u32, bytes[16..20], .little),
        .resize_epoch = std.mem.readInt(u32, bytes[8..12], .little),
        .focused = (bytes[4] & 1) != 0,
        .visible = (bytes[4] & 2) != 0,
    }, &bytes) catch return 3;
    return 0;
}
