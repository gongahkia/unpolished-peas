const std = @import("std");
const contract = @import("contract.zig");
const up = @import("unpolished-peas");
const protocol_game = @import("protocol-game");

const Game = protocol_game.Game;

var game: Game = .{};
var input: up.input.Input = .{};
var context: up.core.GameContext = undefined;
var protocol: up.core.GameProtocol(Game) = undefined;
var initialized = false;
var failure: ?up.core.GameFailure = null;
var headless_memory: [4096]u8 = undefined;

const HeadlessResult = struct {
    image_hash: u64,
    command_count: u32,
};

pub export fn up_browser_protocol_init() i32 {
    input = .{};
    context = .init(&input);
    game = .{};
    protocol = .bind(&game);
    protocol.init(&context) catch |err| {
        retainFailure(.init, err);
        return @intFromEnum(contract.Status.rejected);
    };
    initialized = true;
    failure = null;
    return @intFromEnum(contract.Status.ok);
}

pub export fn up_browser_protocol_frame(elapsed_seconds: f32, interpolation_alpha: f32) i32 {
    if (!initialized) return @intFromEnum(contract.Status.rejected);
    protocol.update(&context, elapsed_seconds) catch |err| {
        retainFailure(.update, err);
        return @intFromEnum(contract.Status.rejected);
    };
    protocol.draw(&context, interpolation_alpha) catch |err| {
        retainFailure(.draw, err);
        return @intFromEnum(contract.Status.rejected);
    };
    failure = null;
    return @intFromEnum(contract.Status.ok);
}

fn retainFailure(phase: up.core.GamePhase, err: anyerror) void {
    failure = protocol.lastFailure() orelse .{ .phase = phase, .cause = err };
}

pub export fn up_browser_protocol_failure_phase() i32 {
    return if (failure) |current| @intFromEnum(current.phase) else -1;
}

pub export fn up_browser_protocol_headless_image_hash() u64 {
    return (headlessResult() catch return 0).image_hash;
}

pub export fn up_browser_protocol_headless_expected_image_hash() u64 {
    return protocol_game.expected_headless_image_hash;
}

pub export fn up_browser_protocol_headless_command_count() u32 {
    return (headlessResult() catch return 0).command_count;
}

fn headlessResult() !HeadlessResult {
    var fixed = std.heap.FixedBufferAllocator.init(&headless_memory);
    var runner = try up.testSupport.HeadlessGameRunner(protocol_game.HeadlessGame).init(fixed.allocator(), protocol_game.headless_width, protocol_game.headless_height);
    defer runner.deinit();
    try runner.run(&protocol_game.headless_frames);
    try runner.submit(&protocol_game.headless_commands);
    const capture = runner.capture();
    return .{ .image_hash = capture.image_hash, .command_count = @intCast(capture.commands.len) };
}

test "browser protocol runtime runs the shared callback game" {
    try std.testing.expectEqual(@as(i32, @intFromEnum(contract.Status.ok)), up_browser_protocol_init());
    try std.testing.expectEqual(@as(i32, @intFromEnum(contract.Status.ok)), up_browser_protocol_frame(1.0 / 60.0, 0.5));
    try std.testing.expectEqual(@as(i32, -1), up_browser_protocol_failure_phase());
}

test "browser protocol runtime shares the headless fixture capture" {
    try std.testing.expectEqual(protocol_game.expected_headless_image_hash, up_browser_protocol_headless_image_hash());
    try std.testing.expectEqual(@as(u32, protocol_game.headless_commands.len), up_browser_protocol_headless_command_count());
}
