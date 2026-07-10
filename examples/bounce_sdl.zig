const std = @import("std");
const up = @import("unpolished");
const sdl = @import("unpolished_sdl3");

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
    ball: Ball = .{},

    pub fn init(_: std.mem.Allocator) !Game {
        return .{};
    }

    pub fn deinit(_: *Game) void {}

    pub fn update(self: *Game, frame: sdl.Frame) !void {
        self.ball.update(frame.dt, frame.input.*);
    }

    pub fn render(self: *Game, frame: sdl.Frame) !void {
        var x: i32 = 0;
        while (x < @as(i32, @intCast(frame.canvas.width))) : (x += 16) {
            frame.canvas.line(x, 0, x, @intCast(frame.canvas.height - 1), up.Color.rgb(32, 39, 50));
        }
        var y: i32 = 0;
        while (y < @as(i32, @intCast(frame.canvas.height))) : (y += 16) {
            frame.canvas.line(0, y, @intCast(frame.canvas.width - 1), y, up.Color.rgb(32, 39, 50));
        }
        frame.canvas.strokeRect(0, 0, @intCast(frame.canvas.width), @intCast(frame.canvas.height), up.Color.rgb(91, 104, 124));
        frame.canvas.fillCircle(@intFromFloat(self.ball.pos.x), @intFromFloat(self.ball.pos.y), self.ball.radius, up.Color.rgb(255, 198, 74));
        frame.canvas.drawText("SDL_GPU", 4, 4, up.Color.rgb(225, 232, 240));
        if (frame.input.isDown(.action)) {
            frame.canvas.drawText("ACTION", 4, 76, up.Color.rgb(113, 232, 162));
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var args = try std.process.argsWithAllocator(gpa.allocator());
    defer args.deinit();

    var max_frames: ?u32 = null;
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--frames")) {
            const value = args.next() orelse return error.MissingFrameCount;
            max_frames = try std.fmt.parseInt(u32, value, 10);
        }
    }

    try sdl.run(gpa.allocator(), .{
        .title = "unpolished SDL_GPU",
        .width = width,
        .height = height,
        .scale = 4,
        .fixed_hz = 60,
        .clear_color = up.Color.rgb(14, 18, 24),
        .max_frames = max_frames,
    }, Game);
}
