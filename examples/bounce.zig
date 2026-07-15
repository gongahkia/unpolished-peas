const std = @import("std");
const up = @import("unpolished-peas").api;

pub const width = 160;
pub const height = 90;

pub const Ball = struct {
    pos: up.Vec2 = .{ .x = 30, .y = 30 },
    vel: up.Vec2 = .{ .x = 52, .y = 37 },
    radius: i32 = 6,

    pub fn update(self: *Ball, dt: f32, bounds_w: f32, bounds_h: f32) void {
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
        if (self.pos.x > bounds_w - r) {
            self.pos.x = bounds_w - r;
            self.vel.x = -self.vel.x;
        }
        if (self.pos.y > bounds_h - r) {
            self.pos.y = bounds_h - r;
            self.vel.y = -self.vel.y;
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var canvas = try up.Canvas.init(allocator, width, height);
    defer canvas.deinit();

    var clock = up.StepClock.init(60);
    var ball = Ball{};

    var frame: u32 = 0;
    while (frame < 180) : (frame += 1) {
        const steps = clock.push(1.0 / 60.0);
        var i: u32 = 0;
        while (i < steps) : (i += 1) {
            ball.update(clock.step_seconds, @floatFromInt(canvas.width), @floatFromInt(canvas.height));
        }

        canvas.clear(up.Color.rgb(14, 18, 24));
        var x: i32 = 0;
        while (x < @as(i32, @intCast(canvas.width))) : (x += 16) {
            canvas.line(x, 0, x, @intCast(canvas.height - 1), up.Color.rgb(32, 39, 50));
        }
        var y: i32 = 0;
        while (y < @as(i32, @intCast(canvas.height))) : (y += 16) {
            canvas.line(0, y, @intCast(canvas.width - 1), y, up.Color.rgb(32, 39, 50));
        }
        canvas.strokeRect(0, 0, @intCast(canvas.width), @intCast(canvas.height), up.Color.rgb(91, 104, 124));
        canvas.fillCircle(@intFromFloat(ball.pos.x), @intFromFloat(ball.pos.y), ball.radius, up.Color.rgb(255, 198, 74));
        canvas.drawText("UNPOLISHED", 4, 4, up.Color.rgb(225, 232, 240));
    }

    try std.fs.cwd().makePath("zig-out");
    try canvas.writePpmFile("zig-out/bounce.ppm");

    var buffer: [256]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buffer);
    const out = &writer.interface;
    try out.print("wrote zig-out/bounce.ppm\n", .{});
    try out.flush();
}
