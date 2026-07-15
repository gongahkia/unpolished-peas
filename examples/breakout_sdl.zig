const up = @import("unpolished-peas").api;
const sdl = @import("unpolished-peas-sdl3");
const breakout = @import("breakout_game.zig");

const Game = struct {
    pub const config: sdl.Config = .{
        .title = "unpolished-peas Breakout",
        .width = breakout.width,
        .height = breakout.height,
        .scale = 5,
        .fixed_hz = 60,
        .clear_color = up.Color.rgb(10, 14, 26),
    };

    game: breakout.Game = .{},
    ball: up.ImageHandle,
    blip: up.Sound,

    pub fn init(ctx: *sdl.Context) !Game {
        const path = try ctx.assetPath("blip.wav");
        defer ctx.allocator.free(path);
        return .{ .ball = try ctx.loadPng("ball.png"), .blip = try up.Sound.loadWav(ctx.allocator, path) };
    }

    pub fn deinit(self: *Game, _: *sdl.Context) void {
        self.blip.deinit();
    }

    pub fn update(self: *Game, ctx: *sdl.Context) !void {
        const axis: f32 = if (ctx.input.isDown(.left)) -1 else if (ctx.input.isDown(.right)) 1 else 0;
        const event = self.game.step(ctx.dt, axis);
        if (event.brick or event.paddle) _ = try ctx.audio.playSound(&self.blip, .{ .volume = 0.35 });
    }

    pub fn draw(self: *Game, ctx: *sdl.Context) !void {
        for (self.game.bricks, 0..) |active, index| {
            if (!active) continue;
            const brick = breakout.Game.brickRect(index);
            ctx.rect(@intFromFloat(brick.x), @intFromFloat(brick.y), @intFromFloat(brick.w), @intFromFloat(brick.h), breakout.Game.brickColor(index));
        }
        ctx.rect(@intFromFloat(self.game.paddle.x), @intFromFloat(self.game.paddle.y), @intFromFloat(self.game.paddle.w), @intFromFloat(self.game.paddle.h), up.Color.rgb(225, 232, 240));
        try ctx.image(self.ball, @intFromFloat(self.game.ball.x - 4), @intFromFloat(self.game.ball.y - 4));
        ctx.text("BREAKOUT", 4, 2, up.Color.white);
        ctx.text("LEFT RIGHT", 104, 2, up.Color.rgb(180, 200, 230));
    }
};

pub fn main() !void {
    try sdl.playGame(Game);
}
