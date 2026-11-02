const std = @import("std");
const up = @import("unpolished-peas");
const sdl = @import("unpolished-peas-sdl3");
const protocol_game = @import("protocol_game.zig");

const Game = struct {
    pub const config: sdl.Config = .{
        .title = "protocol desktop fixture",
        .width = 64,
        .height = 48,
        .scale = 2,
        .fixed_hz = 60,
        .max_frames = 2,
        .clear_color = up.core.Color.rgb(12, 18, 28),
    };

    game: protocol_game.Game = .{},

    pub fn init(self: *@This(), ctx: *up.core.GameContext) !void {
        try self.game.init(ctx);
    }

    pub fn update(self: *@This(), ctx: *up.core.GameContext, elapsed_seconds: f32) !void {
        try self.game.update(ctx, elapsed_seconds);
    }

    pub fn draw(self: *@This(), ctx: *up.core.GameContext) !void {
        const canvas = try ctx.requireCanvas();
        try self.game.draw(ctx);
        canvas.fillRect(@intFromFloat(self.game.position.x), @intFromFloat(self.game.position.y), 8, 8, up.core.Color.rgb(255, 198, 74));
    }
};

comptime {
    _ = up.core.GameProtocol(Game);
}

pub fn main() !void {
    try sdl.playGame(Game);
}

test "protocol game updates without desktop loop access" {
    var input = up.input.Input{};
    input.set(.right, true);
    var context = up.core.GameContext.init(&input);
    var game = Game{};
    var protocol = up.core.GameProtocol(Game).bind(&game);
    try protocol.init(&context);
    try protocol.update(&context, 0.5);
    try std.testing.expectEqual(@as(f32, 44), game.game.position.x);
}
