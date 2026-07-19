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

test "browser protocol runtime runs the shared callback game" {
    try std.testing.expectEqual(@as(i32, @intFromEnum(contract.Status.ok)), up_browser_protocol_init());
    try std.testing.expectEqual(@as(i32, @intFromEnum(contract.Status.ok)), up_browser_protocol_frame(1.0 / 60.0, 0.5));
    try std.testing.expectEqual(@as(i32, -1), up_browser_protocol_failure_phase());
}
