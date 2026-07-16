const std = @import("std");
const up = @import("unpolished-peas");

pub const Input = struct { left: bool = false, right: bool = false, jump: bool = false };
pub const Diagnostics = struct {
    position: up.Vec2,
    velocity: up.Vec2,
    state: up.CharacterState,
};

pub const Game = struct {
    controller: up.CharacterController,
    velocity: up.Vec2 = .{},

    pub fn init(position: up.Vec2) !Game {
        return .{ .controller = try .init(.{ .bounds = .{ .x = position.x, .y = position.y, .w = 8, .h = 12 }, .max_step_height = 8 }) };
    }

    pub fn step(self: *Game, collider: *const up.TileCollider, input: Input, dt: f32) up.CharacterState {
        const axis: f32 = if (input.left) -1 else if (input.right) 1 else 0;
        self.velocity.x = axis * 44;
        if (input.jump and self.controller.grounded) self.velocity.y = -88;
        self.velocity.y = @min(self.velocity.y + 220 * dt, 120);
        const state = self.controller.move(collider, self.velocity.scale(dt));
        if (state.grounded and self.velocity.y > 0) self.velocity.y = 0;
        return state;
    }

    pub fn diagnostics(self: Game) Diagnostics {
        return .{ .position = .{ .x = self.controller.bounds.x, .y = self.controller.bounds.y }, .velocity = self.velocity, .state = .{ .bounds = self.controller.bounds, .grounded = self.controller.grounded, .wall_left = self.controller.wall_left, .wall_right = self.controller.wall_right, .ceiling = self.controller.ceiling } };
    }
};

fn loadCollider(allocator: std.mem.Allocator) !struct { map: up.TileMap, collider: up.TileCollider } {
    var map = try up.TileMap.init(allocator, .{ .x = 16, .y = 16 }, 8);
    errdefer map.deinit();
    const layer = try map.addLayer("collision", .int_grid, null);
    var x: i32 = -4;
    while (x < 16) : (x += 1) try map.setIntGrid(layer, .{ .x = x, .y = 3 }, 1);
    var collider = up.TileCollider.init(allocator);
    errdefer collider.deinit();
    try collider.addLayer(&map, layer);
    return .{ .map = map, .collider = collider };
}

test "platformer movement fixture lands and jumps deterministically" {
    var fixture = try loadCollider(std.testing.allocator);
    defer fixture.collider.deinit();
    defer fixture.map.deinit();
    var game = try Game.init(.{ .x = 8, .y = 0 });
    var frame: u32 = 0;
    while (frame < 120) : (frame += 1) _ = game.step(&fixture.collider, .{ .right = true }, 1.0 / 60.0);
    try std.testing.expect(game.controller.grounded);
    _ = game.step(&fixture.collider, .{ .jump = true }, 1.0 / 60.0);
    try std.testing.expect(game.velocity.y < 0);
}

test "stored platformer replay has a stable state hash" {
    var fixture = try loadCollider(std.testing.allocator);
    defer fixture.collider.deinit();
    defer fixture.map.deinit();
    var replay = try up.parseInputReplay(std.testing.allocator, @embedFile("replays/platformer.upr"));
    defer replay.deinit(std.testing.allocator);
    var game = try Game.init(.{ .x = 8, .y = 0 });
    for (replay.frames) |frame| _ = game.step(&fixture.collider, .{ .left = (frame.buttons & 1) != 0, .right = (frame.buttons & 2) != 0, .jump = (frame.buttons & 4) != 0 }, up.testSupport.frameSeconds(replay.fixed_hz));
    const hash = replayHash(game);
    try up.testSupport.assertReplayHash(std.testing.allocator, 0xa94f6ba5b168f0e6, hash, &replay, "zig-out/diagnostics/replays/platformer");
}

test "platformer exposes structured v1 diagnostics" {
    var game = try Game.init(.{ .x = 8, .y = 0 });
    game.velocity = .{ .x = 12, .y = -4 };
    const diagnostics = game.diagnostics();
    try std.testing.expectEqual(@as(f32, 8), diagnostics.position.x);
    try std.testing.expectEqual(@as(f32, -4), diagnostics.velocity.y);
}

fn replayHash(game: Game) u64 {
    var hash = up.testSupport.StateHash{};
    hash.updateValue(game.controller.bounds.x);
    hash.updateValue(game.controller.bounds.y);
    hash.updateValue(game.velocity.x);
    hash.updateValue(game.velocity.y);
    hash.updateBool(game.controller.grounded);
    hash.updateBool(game.controller.wall_left);
    hash.updateBool(game.controller.wall_right);
    hash.updateBool(game.controller.ceiling);
    return hash.finish();
}
