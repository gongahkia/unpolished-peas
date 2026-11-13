const std = @import("std");
const up = @import("unpolished-peas");

pub const width = 160;
pub const height = 96;
pub const player_width = 10;
pub const player_height = 14;
pub const gravity: f32 = 360;
pub const run_speed: f32 = 72;
pub const jump_speed: f32 = -154;
pub const platforms = [_]up.core.Rect{
    .init(0, 84, width, 12),
    .init(20, 64, 36, 6),
    .init(72, 54, 32, 6),
    .init(118, 68, 24, 6),
};
pub const actions = [_]up.input.Action{
    .{ .name = "left", .binding = .{ .key = .left } },
    .{ .name = "right", .binding = .{ .key = .right } },
    .{ .name = "jump", .binding = .{ .key = .action } },
};

pub const Event = struct { jumped: bool = false, landed: bool = false, reached_goal: bool = false };
pub const Diagnostics = struct { player: up.core.Vec2, velocity: up.core.Vec2, grounded: bool, jumps: u32, reached_goal: bool };

pub const Game = struct {
    player: up.core.Vec2 = .{ .x = 12, .y = 70 },
    velocity: up.core.Vec2 = .{},
    grounded: bool = false,
    jump_was_down: bool = false,
    jumps: u32 = 0,
    reached_goal: bool = false,

    pub fn step(self: *Game, input: up.input.Input, dt: f32) Event {
        const bindings = up.input.ActionMap{ .actions = &actions };
        const horizontal = bindings.value(input, "game", "right") - bindings.value(input, "game", "left");
        const jump_down = bindings.value(input, "game", "jump") != 0;
        const jumped = jump_down and !self.jump_was_down and self.grounded;
        self.jump_was_down = jump_down;
        if (jumped) {
            self.velocity.y = jump_speed;
            self.grounded = false;
            self.jumps += 1;
        }
        self.velocity.x = horizontal * run_speed;
        self.player.x = std.math.clamp(self.player.x + self.velocity.x * dt, 0, width - player_width);
        const previous_y = self.player.y;
        self.velocity.y += gravity * dt;
        self.player.y += self.velocity.y * dt;
        const was_grounded = self.grounded;
        self.grounded = false;
        for (platforms) |platform| self.resolveVertical(platform, previous_y);
        if (self.player.y > height) self.reset();
        self.reached_goal = self.reached_goal or (self.player.x + player_width >= 150 and self.grounded);
        return .{ .jumped = jumped, .landed = !was_grounded and self.grounded, .reached_goal = self.reached_goal };
    }

    pub fn playerRect(self: Game) up.core.Rect {
        return .init(self.player.x, self.player.y, player_width, player_height);
    }

    pub fn diagnostics(self: Game) Diagnostics {
        return .{ .player = self.player, .velocity = self.velocity, .grounded = self.grounded, .jumps = self.jumps, .reached_goal = self.reached_goal };
    }

    fn resolveVertical(self: *Game, platform: up.core.Rect, previous_y: f32) void {
        const player = self.playerRect();
        if (!player.intersects(platform)) return;
        if (self.velocity.y >= 0 and previous_y + player_height <= platform.y) {
            self.player.y = platform.y - player_height;
            self.velocity.y = 0;
            self.grounded = true;
        } else if (self.velocity.y < 0 and previous_y >= platform.y + platform.h) {
            self.player.y = platform.y + platform.h;
            self.velocity.y = 0;
        }
    }

    fn reset(self: *Game) void {
        self.player = .{ .x = 12, .y = 70 };
        self.velocity = .{};
        self.grounded = false;
    }
};

test "platformer lands on owned platforms" {
    var game = Game{ .player = .{ .x = 24, .y = 12 } };
    var frame: u32 = 0;
    while (frame < 60) : (frame += 1) _ = game.step(.{}, 1.0 / 60.0);
    try std.testing.expect(game.grounded);
    try std.testing.expectApproxEqAbs(@as(f32, 50), game.player.y, 0.001);
    try std.testing.expectEqual(@as(f32, 0), game.velocity.y);
}

test "platformer jump is rising-edge gated" {
    var game = Game{};
    _ = game.step(.{}, 1.0 / 60.0);
    var input = up.input.Input{};
    input.set(.action, true);
    const first = game.step(input, 1.0 / 60.0);
    const held = game.step(input, 1.0 / 60.0);
    try std.testing.expect(first.jumped);
    try std.testing.expect(!held.jumped);
    try std.testing.expectEqual(@as(u32, 1), game.jumps);
}

test "platformer fixed-step state is deterministic" {
    var input = up.input.Input{};
    input.set(.right, true);
    var a = Game{};
    var b = Game{};
    var frame: u32 = 0;
    while (frame < 180) : (frame += 1) {
        if (frame == 5) input.set(.action, true);
        if (frame == 6) input.set(.action, false);
        _ = a.step(input, 1.0 / 60.0);
        _ = b.step(input, 1.0 / 60.0);
    }
    try std.testing.expectEqualDeep(a, b);
    try std.testing.expect(a.reached_goal);
}
