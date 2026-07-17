const up = @import("unpolished-peas");
const sdl = @import("unpolished-peas-sdl3");
const breakout = @import("breakout_game.zig");
const atlas_data = @import("programmatic_atlas.zig");

const Game = struct {
    pub const config: sdl.Config = .{
        .title = "unpolished-peas Breakout",
        .width = breakout.width,
        .height = breakout.height,
        .scale = 5,
        .fixed_hz = 60,
        .clear_color = up.core.Color.rgb(10, 14, 26),
    };

    game: breakout.Game = .{},
    ball: up.assets.ImageHandle,
    blip: up.assets.AudioHandle,
    atlas: *up.assets.Atlas,
    ball_frame: up.assets.AtlasFrameHandle,

    pub fn init(ctx: *sdl.Context) !Game {
        const ball = try ctx.loadImage("ball.png");
        const atlas = try ctx.allocator.create(up.assets.Atlas);
        errdefer ctx.allocator.destroy(atlas);
        atlas.* = try atlas_data.ballAtlas(ctx.allocator, try ctx.assets.tryImage(ball));
        errdefer atlas.deinit();
        const ball_frame = atlas.findFrame("tile_a") orelse return error.MissingAtlasFrame;
        return .{ .ball = ball, .blip = try ctx.loadSound("blip.wav"), .atlas = atlas, .ball_frame = ball_frame };
    }

    pub fn deinit(self: *Game, _: *sdl.Context) void {
        const allocator = self.atlas.allocator;
        self.atlas.deinit();
        allocator.destroy(self.atlas);
    }

    pub fn update(self: *Game, ctx: *sdl.Context) !void {
        const axis: f32 = if (ctx.input.isDown(.left)) -1 else if (ctx.input.isDown(.right)) 1 else 0;
        const event = self.game.step(ctx.dt, axis);
        if (event.brick or event.paddle) _ = try ctx.audio.playSound(try ctx.assets.trySoundPtr(self.blip), .{ .volume = 0.35 });
    }

    pub fn draw(self: *Game, ctx: *sdl.Context) !void {
        for (self.game.bricks, 0..) |active, index| {
            if (!active) continue;
            const brick = breakout.Game.brickRect(index);
            ctx.rect(@intFromFloat(brick.x), @intFromFloat(brick.y), @intFromFloat(brick.w), @intFromFloat(brick.h), breakout.Game.brickColor(index));
        }
        ctx.rect(@intFromFloat(self.game.paddle.x), @intFromFloat(self.game.paddle.y), @intFromFloat(self.game.paddle.w), @intFromFloat(self.game.paddle.h), up.core.Color.rgb(225, 232, 240));
        try ctx.spriteAtlas(self.atlas, self.ball_frame, @intFromFloat(self.game.ball.x - 4), @intFromFloat(self.game.ball.y - 4), .{});
        ctx.text("BREAKOUT", 4, 2, up.core.Color.white);
        ctx.text("LEFT RIGHT", 104, 2, up.core.Color.rgb(180, 200, 230));
    }
};

pub fn main() !void {
    try sdl.playGame(Game);
}
