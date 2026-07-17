const std = @import("std");
const up = @import("unpolished-peas");

pub const width = 160;
pub const height = 96;
pub const brick_columns = 10;
pub const brick_rows = 4;
pub const brick_count = brick_columns * brick_rows;

pub const Event = struct { paddle: bool = false, brick: bool = false, lost: bool = false, won: bool = false };

pub const Diagnostics = struct {
    score: u32,
    lives: u8,
    active_bricks: usize,
    won: bool,
};

pub const Game = struct {
    paddle: up.core.Rect = .{ .x = 64, .y = 88, .w = 32, .h = 4 },
    ball: up.core.Rect = .{ .x = 76, .y = 68, .w = 8, .h = 8 },
    velocity: up.core.Vec2 = .{ .x = 64, .y = -72 },
    bricks: [brick_count]bool = [_]bool{true} ** brick_count,
    score: u32 = 0,
    lives: u8 = 3,

    pub fn step(self: *Game, dt: f32, paddle_axis: f32) Event {
        var event = Event{};
        self.paddle.x = std.math.clamp(self.paddle.x + std.math.clamp(paddle_axis, -1, 1) * 112 * dt, 0, @as(f32, @floatFromInt(width)) - self.paddle.w);
        self.ball.x += self.velocity.x * dt;
        if (self.ball.x < 0 or self.ball.x + self.ball.w > width) {
            self.ball.x = std.math.clamp(self.ball.x, 0, @as(f32, @floatFromInt(width)) - self.ball.w);
            self.velocity.x = -self.velocity.x;
        }
        self.ball.y += self.velocity.y * dt;
        if (self.ball.y < 0) {
            self.ball.y = 0;
            self.velocity.y = -self.velocity.y;
        }
        if (self.velocity.y > 0 and up.core.Rect.intersects(self.ball, self.paddle)) {
            self.ball.y = self.paddle.y - self.ball.h;
            self.velocity.y = -self.velocity.y;
            self.velocity.x += (self.ball.x + self.ball.w / 2 - (self.paddle.x + self.paddle.w / 2)) * 2;
            event.paddle = true;
        }
        for (&self.bricks, 0..) |*active, index| {
            if (!active.* or !up.core.Rect.intersects(self.ball, brickRect(index))) continue;
            active.* = false;
            self.score += 1;
            self.velocity.y = -self.velocity.y;
            event.brick = true;
            break;
        }
        if (self.ball.y > height) {
            if (self.lives > 0) self.lives -= 1;
            self.ball = .{ .x = 76, .y = 68, .w = 8, .h = 8 };
            self.velocity = .{ .x = 64, .y = -72 };
            event.lost = true;
        }
        event.won = self.score == brick_count;
        return event;
    }

    pub fn brickRect(index: usize) up.core.Rect {
        return .{
            .x = 8 + @as(f32, @floatFromInt(index % brick_columns)) * 15,
            .y = 12 + @as(f32, @floatFromInt(index / brick_columns)) * 7,
            .w = 13,
            .h = 5,
        };
    }

    pub fn brickColor(index: usize) up.core.Color {
        return switch (index / brick_columns) {
            0 => up.core.Color.rgb(255, 112, 112),
            1 => up.core.Color.rgb(255, 198, 74),
            2 => up.core.Color.rgb(113, 232, 162),
            else => up.core.Color.rgb(91, 166, 210),
        };
    }

    pub fn diagnostics(self: Game) Diagnostics {
        var active_bricks: usize = 0;
        for (self.bricks) |active| {
            if (active) active_bricks += 1;
        }
        return .{ .score = self.score, .lives = self.lives, .active_bricks = active_bricks, .won = self.score == brick_count };
    }

    pub fn drawHeadless(self: Game, canvas: *up.graphics.Canvas, ball_image: up.assets.Image) void {
        canvas.clear(up.core.Color.rgb(10, 14, 26));
        for (self.bricks, 0..) |active, index| {
            if (!active) continue;
            const brick = brickRect(index);
            canvas.fillRect(@intFromFloat(brick.x), @intFromFloat(brick.y), @intFromFloat(brick.w), @intFromFloat(brick.h), brickColor(index));
        }
        canvas.fillRect(@intFromFloat(self.paddle.x), @intFromFloat(self.paddle.y), @intFromFloat(self.paddle.w), @intFromFloat(self.paddle.h), up.core.Color.rgb(225, 232, 240));
        canvas.drawImage(ball_image, @intFromFloat(self.ball.x - 4), @intFromFloat(self.ball.y - 4));
        canvas.drawText("BREAKOUT", 4, 2, up.core.Color.white);
    }

    pub fn drawHeadlessAtlas(self: Game, canvas: *up.graphics.Canvas, atlas: up.assets.Atlas, frame: up.assets.AtlasFrameHandle) void {
        canvas.clear(up.core.Color.rgb(10, 14, 26));
        for (self.bricks, 0..) |active, index| {
            if (!active) continue;
            const brick = brickRect(index);
            canvas.fillRect(@intFromFloat(brick.x), @intFromFloat(brick.y), @intFromFloat(brick.w), @intFromFloat(brick.h), brickColor(index));
        }
        canvas.fillRect(@intFromFloat(self.paddle.x), @intFromFloat(self.paddle.y), @intFromFloat(self.paddle.w), @intFromFloat(self.paddle.h), up.core.Color.rgb(225, 232, 240));
        canvas.drawAtlasFrame(atlas, frame, @intFromFloat(self.ball.x - 4), @intFromFloat(self.ball.y - 4), .{});
        canvas.drawText("BREAKOUT", 4, 2, up.core.Color.white);
    }
};

test "breakout resolves bricks and fixed-step state deterministically" {
    var hit = Game{};
    hit.ball = .{ .x = 10, .y = 20, .w = 8, .h = 8 };
    hit.velocity = .{ .x = 0, .y = -120 };
    try std.testing.expect(hit.step(0.1, 0).brick);
    try std.testing.expectEqual(@as(u32, 1), hit.score);
    try std.testing.expect(!hit.bricks[0]);

    var a = Game{};
    var b = Game{};
    var frame: u32 = 0;
    while (frame < 360) : (frame += 1) {
        const axis: f32 = if ((frame / 90) % 2 == 0) 1 else -1;
        _ = a.step(1.0 / 60.0, axis);
        _ = b.step(1.0 / 60.0, axis);
    }
    try std.testing.expectEqualDeep(a, b);
}

test "stored Breakout replay has a stable state hash" {
    var replay = try up.preview.developer.parseInputReplay(std.testing.allocator, @embedFile("replays/breakout.upr"));
    defer replay.deinit(std.testing.allocator);
    var game = Game{};
    for (replay.frames) |frame| {
        const axis: f32 = if ((frame.buttons & 1) != 0) -1 else if ((frame.buttons & 2) != 0) 1 else 0;
        _ = game.step(up.testSupport.frameSeconds(replay.fixed_hz), axis);
    }
    const hash = replayHash(game);
    try up.testSupport.assertReplayHash(std.testing.allocator, 0x2d407efdf7179fce, hash, &replay, "zig-out/diagnostics/replays/breakout");
}

test "breakout exposes structured v1 diagnostics" {
    var game = Game{};
    game.bricks[0] = false;
    game.score = 1;
    const diagnostics = game.diagnostics();
    try std.testing.expectEqual(@as(u32, 1), diagnostics.score);
    try std.testing.expectEqual(@as(u8, 3), diagnostics.lives);
    try std.testing.expectEqual(brick_count - 1, diagnostics.active_bricks);
    try std.testing.expect(!diagnostics.won);
}

test "Breakout atlas draw contract preserves headless WebGL coordinates" {
    const pixels = try std.testing.allocator.alloc(up.core.Color, 64);
    defer std.testing.allocator.free(pixels);
    @memset(pixels, up.core.Color.rgb(255, 255, 255));
    var image = up.assets.Image{ .allocator = std.testing.allocator, .width = 8, .height = 8, .pixels = pixels };
    var atlas = try up.assets.Atlas.init(std.testing.allocator, try image.clone(std.testing.allocator), "memory", &.{.{ .name = "ball", .x = 0, .y = 0, .w = 8, .h = 8 }}, &.{});
    defer atlas.deinit();
    var direct = try up.graphics.Canvas.init(std.testing.allocator, width, height);
    defer direct.deinit();
    var atlas_canvas = try up.graphics.Canvas.init(std.testing.allocator, width, height);
    defer atlas_canvas.deinit();
    const game = Game{};
    game.drawHeadless(&direct, image);
    game.drawHeadlessAtlas(&atlas_canvas, atlas, atlas.findFrame("ball").?);
    try std.testing.expectEqual(up.testSupport.canvasHash(direct), up.testSupport.canvasHash(atlas_canvas));
}

fn replayHash(game: Game) u64 {
    var hash = up.testSupport.StateHash{};
    hash.updateValue(game.paddle.x);
    hash.updateValue(game.ball.x);
    hash.updateValue(game.ball.y);
    hash.updateValue(game.velocity.x);
    hash.updateValue(game.velocity.y);
    hash.updateValue(game.score);
    hash.updateValue(game.lives);
    for (game.bricks) |brick| hash.updateBool(brick);
    return hash.finish();
}
