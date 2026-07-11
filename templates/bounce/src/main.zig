const up = @import("unpolished-peas");
const sdl = @import("unpolished-peas-sdl3");

const width = 160;
const height = 90;

const Game = struct {
    pos: up.Vec2 = .{ .x = 76, .y = 41 },
    vel: up.Vec2 = .{ .x = 50, .y = 36 },

    pub fn update(self: *Game, ctx: *sdl.Context) void {
        var accel = up.Vec2{};
        if (ctx.down(.left)) accel.x -= 120;
        if (ctx.down(.right)) accel.x += 120;
        if (ctx.down(.up)) accel.y -= 120;
        if (ctx.down(.down)) accel.y += 120;

        self.vel = self.vel.add(accel.scale(ctx.dt));
        self.pos = self.pos.add(self.vel.scale(ctx.dt));
        if (self.pos.x < 4 or self.pos.x > width - 12) self.vel.x = -self.vel.x;
        if (self.pos.y < 4 or self.pos.y > height - 12) self.vel.y = -self.vel.y;
    }

    pub fn draw(self: *Game, ctx: *sdl.Context) void {
        ctx.rect(@intFromFloat(self.pos.x), @intFromFloat(self.pos.y), 8, 8, up.Color.rgb(255, 198, 74));
        ctx.text("BOUNCING SQUARE", 4, 4, up.Color.rgb(225, 232, 240));
    }
};

pub fn main() !void {
    try sdl.play(.{
        .title = "bouncing-square",
        .organization = "your-name",
        .application = "bouncing-square",
        .width = width,
        .height = height,
        .scale = 5,
        .clear_color = up.Color.rgb(14, 18, 24),
    }, Game);
}
