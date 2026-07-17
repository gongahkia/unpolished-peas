const std = @import("std");
const up = @import("unpolished-peas");
const sdl = @import("unpolished-peas-sdl3");

const Game = struct {
    pub const config: sdl.Config = .{
        .title = "external sprite audio input",
        .organization = "fixture",
        .application = "external-sprite-audio-input",
        .width = 64,
        .height = 48,
        .scale = 4,
        .fixed_hz = 60,
        .max_frames = 2,
        .clear_color = up.core.Color.rgb(12, 18, 28),
    };

    position: up.core.Vec2 = .{ .x = 24, .y = 18 },
    sprite: up.assets.Image,
    blip: up.assets.Sound,

    pub fn init(ctx: *sdl.Context) !Game {
        return initResources(ctx.allocator);
    }

    pub fn deinit(self: *Game, _: *sdl.Context) void {
        self.sprite.deinit();
        self.blip.deinit();
    }

    pub fn update(self: *Game, ctx: *sdl.Context) !void {
        if (self.advance(ctx.input.*, ctx.dt)) _ = try ctx.audio.playSound(&self.blip, .{ .volume = 0.2 });
    }

    pub fn draw(self: *Game, ctx: *sdl.Context) void {
        ctx.canvas.drawImage(self.sprite, @intFromFloat(self.position.x), @intFromFloat(self.position.y));
        ctx.text("ARROWS + SPACE", 2, 2, up.core.Color.white);
    }

    fn initResources(allocator: std.mem.Allocator) !Game {
        const pixels = try allocator.alloc(up.core.Color, 4);
        errdefer allocator.free(pixels);
        pixels[0] = up.core.Color.rgb(255, 198, 74);
        pixels[1] = up.core.Color.rgb(113, 232, 162);
        pixels[2] = up.core.Color.rgb(113, 232, 162);
        pixels[3] = up.core.Color.rgb(255, 198, 74);
        const frames = try allocator.alloc(up.assets.AudioSample, 2);
        errdefer allocator.free(frames);
        frames[0] = .{ .left = 0.2, .right = 0.2 };
        frames[1] = .{ .left = -0.2, .right = -0.2 };
        return .{
            .sprite = .{ .allocator = allocator, .width = 2, .height = 2, .pixels = pixels },
            .blip = .{ .allocator = allocator, .sample_rate = 48_000, .frames = frames },
        };
    }

    fn advance(self: *Game, input: up.input.Input, dt: f32) bool {
        const speed: f32 = 40;
        if (input.isDown(.left)) self.position.x -= speed * dt;
        if (input.isDown(.right)) self.position.x += speed * dt;
        if (input.isDown(.up)) self.position.y -= speed * dt;
        if (input.isDown(.down)) self.position.y += speed * dt;
        return input.wasPressed(.action);
    }
};

pub fn main() !void {
    try sdl.playGame(Game);
}

test "external fixture advances its sprite and triggers audio from input" {
    var game = try Game.initResources(std.testing.allocator);
    defer {
        game.sprite.deinit();
        game.blip.deinit();
    }
    var input = up.input.Input{};
    input.set(.right, true);
    input.set(.action, true);
    try std.testing.expect(game.advance(input, 0.5));
    try std.testing.expectEqual(@as(f32, 44), game.position.x);
    try std.testing.expectEqual(@as(u32, 2), game.sprite.width);
    try std.testing.expectEqual(@as(usize, 2), game.blip.frames.len);
}
