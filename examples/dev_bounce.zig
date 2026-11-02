const up = @import("unpolished-peas");
const sdl = @import("unpolished-peas-sdl3");

const width = 160;
const height = 90;

const Game = struct {
    pub const config: sdl.Config = .{
        .title = "unpolished-peas dev bounce",
        .width = width,
        .height = height,
        .scale = 4,
        .clear_color = up.core.Color.rgb(14, 18, 24),
    };

    ball: Ball = .{},
    sprite: up.assets.ImageHandle,
    message: up.assets.TextHandle,

    pub fn init(ctx: *sdl.Context) !Game {
        return .{
            .sprite = try ctx.loadImage("ball.png"),
            .message = try ctx.loadText("message.txt"),
        };
    }

    pub fn update(self: *Game, ctx: *sdl.Context) void {
        self.ball.update(ctx);
    }

    pub fn draw(self: *Game, ctx: *sdl.Context) !void {
        try ctx.image(self.sprite, @intFromFloat(self.ball.pos.x), @intFromFloat(self.ball.pos.y));
        ctx.text(try ctx.textAsset(self.message), 4, 4, up.core.Color.rgb(225, 232, 240));
        ctx.text("EDIT assets/message.txt", 4, 76, up.core.Color.rgb(113, 232, 162));
    }
};

const Ball = struct {
    pos: up.core.Vec2 = .{ .x = 40, .y = 38 },
    vel: up.core.Vec2 = .{ .x = 46, .y = 32 },

    fn update(self: *Ball, ctx: *sdl.Context) void {
        var accel = up.core.Vec2{};
        if (ctx.down(.left)) accel.x -= 120;
        if (ctx.down(.right)) accel.x += 120;
        if (ctx.down(.up)) accel.y -= 120;
        if (ctx.down(.down)) accel.y += 120;

        self.vel = self.vel.add(accel.scale(ctx.dt));
        self.pos = self.pos.add(self.vel.scale(ctx.dt));
        if (self.pos.x < 8 or self.pos.x > width - 8) self.vel.x = -self.vel.x;
        if (self.pos.y < 8 or self.pos.y > height - 8) self.vel.y = -self.vel.y;
    }
};

pub fn main() !void {
    try sdl.playGame(Game);
}
