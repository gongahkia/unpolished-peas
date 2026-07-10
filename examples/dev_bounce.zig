const std = @import("std");
const up = @import("unpolished");
const sdl = @import("unpolished_sdl3");

const width = 160;
const height = 90;

const Game = struct {
    ball: Ball = .{},
    sprite: ?up.ImageHandle = null,
    message: ?up.TextHandle = null,

    pub fn init(_: std.mem.Allocator) !Game {
        return .{};
    }

    pub fn deinit(_: *Game) void {}

    pub fn update(self: *Game, frame: sdl.Frame) !void {
        try self.ensureAssets(frame.assets);
        self.ball.update(frame.dt, frame.input.*);
    }

    pub fn render(self: *Game, frame: sdl.Frame) !void {
        try self.ensureAssets(frame.assets);
        drawGrid(frame.canvas);

        if (self.sprite) |handle| {
            const image = frame.assets.image(handle);
            frame.canvas.drawImage(image, @intFromFloat(self.ball.pos.x) - @as(i32, @intCast(image.width / 2)), @intFromFloat(self.ball.pos.y) - @as(i32, @intCast(image.height / 2)));
        }

        if (self.message) |handle| {
            frame.canvas.drawText(frame.assets.text(handle), 4, 4, up.Color.rgb(225, 232, 240));
        }
        frame.canvas.drawText("EDIT examples/assets/message.txt", 4, 76, up.Color.rgb(113, 232, 162));
    }

    fn ensureAssets(self: *Game, assets: *up.AssetStore) !void {
        if (self.sprite == null) self.sprite = try assets.loadPng("examples/assets/ball.png");
        if (self.message == null) self.message = try assets.loadText("examples/assets/message.txt");
    }
};

const Ball = struct {
    pos: up.Vec2 = .{ .x = 40, .y = 38 },
    vel: up.Vec2 = .{ .x = 46, .y = 32 },

    fn update(self: *Ball, dt: f32, input: up.Input) void {
        var accel = up.Vec2{};
        if (input.isDown(.left)) accel.x -= 120;
        if (input.isDown(.right)) accel.x += 120;
        if (input.isDown(.up)) accel.y -= 120;
        if (input.isDown(.down)) accel.y += 120;

        self.vel = self.vel.add(accel.scale(dt));
        self.pos = self.pos.add(self.vel.scale(dt));
        if (self.pos.x < 8 or self.pos.x > width - 8) self.vel.x = -self.vel.x;
        if (self.pos.y < 8 or self.pos.y > height - 8) self.vel.y = -self.vel.y;
    }
};

fn drawGrid(canvas: *up.Canvas) void {
    var x: i32 = 0;
    while (x < @as(i32, @intCast(canvas.width))) : (x += 16) {
        canvas.line(x, 0, x, @intCast(canvas.height - 1), up.Color.rgb(32, 39, 50));
    }
    var y: i32 = 0;
    while (y < @as(i32, @intCast(canvas.height))) : (y += 16) {
        canvas.line(0, y, @intCast(canvas.width - 1), y, up.Color.rgb(32, 39, 50));
    }
}

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
        .title = "unpolished dev bounce",
        .width = width,
        .height = height,
        .scale = 4,
        .clear_color = up.Color.rgb(14, 18, 24),
        .max_frames = max_frames,
    }, Game);
}
