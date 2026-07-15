const up = @import("unpolished-peas").api;
const sdl = @import("unpolished-peas-sdl3");

const width = 160;
const height = 90;

const Ball = struct {
    pos: up.Vec2 = .{ .x = 30, .y = 30 },
    vel: up.Vec2 = .{ .x = 52, .y = 37 },
    radius: i32 = 6,

    fn update(self: *Ball, dt: f32, input: up.Input) void {
        var accel = up.Vec2{};
        if (input.isDown(.left)) accel.x -= 120;
        if (input.isDown(.right)) accel.x += 120;
        if (input.isDown(.up)) accel.y -= 120;
        if (input.isDown(.down)) accel.y += 120;

        self.vel = self.vel.add(accel.scale(dt));
        self.pos = self.pos.add(self.vel.scale(dt));

        const r: f32 = @floatFromInt(self.radius);
        if (self.pos.x < r) {
            self.pos.x = r;
            self.vel.x = -self.vel.x;
        }
        if (self.pos.y < r) {
            self.pos.y = r;
            self.vel.y = -self.vel.y;
        }
        if (self.pos.x > width - r) {
            self.pos.x = width - r;
            self.vel.x = -self.vel.x;
        }
        if (self.pos.y > height - r) {
            self.pos.y = height - r;
            self.vel.y = -self.vel.y;
        }
    }
};

const Game = struct {
    pub const config: sdl.Config = .{
        .title = "unpolished-peas SDL3",
        .width = width,
        .height = height,
        .scale = 4,
        .resizable = true,
        .fixed_hz = 60,
        .clear_color = up.Color.rgb(14, 18, 24),
    };

    ball: Ball = .{},

    pub fn update(self: *Game, ctx: *sdl.Context) void {
        self.ball.update(ctx.dt, ctx.input.*);
    }

    pub fn draw(self: *Game, ctx: *sdl.Context) void {
        var x: i32 = 0;
        while (x < @as(i32, @intCast(ctx.canvas.width))) : (x += 16) {
            ctx.canvas.line(x, 0, x, @intCast(ctx.canvas.height - 1), up.Color.rgb(32, 39, 50));
        }
        var y: i32 = 0;
        while (y < @as(i32, @intCast(ctx.canvas.height))) : (y += 16) {
            ctx.canvas.line(0, y, @intCast(ctx.canvas.width - 1), y, up.Color.rgb(32, 39, 50));
        }
        ctx.canvas.strokeRect(0, 0, @intCast(ctx.canvas.width), @intCast(ctx.canvas.height), up.Color.rgb(91, 104, 124));
        ctx.canvas.fillCircle(@intFromFloat(self.ball.pos.x), @intFromFloat(self.ball.pos.y), self.ball.radius, up.Color.rgb(255, 198, 74));
        ctx.text("SDL_GPU", 4, 4, up.Color.rgb(225, 232, 240));
        if (ctx.down(.action)) {
            ctx.text("ACTION", 4, 76, up.Color.rgb(113, 232, 162));
        }
    }
};

pub fn main() !void {
    try sdl.playGame(Game);
}
