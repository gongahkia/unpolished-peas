const std = @import("std");
const up = @import("unpolished-peas");

pub const Input = struct { left: bool = false, right: bool = false, jump: bool = false };
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
};

fn loadCollider(allocator: std.mem.Allocator) !struct { map: up.TileMap, collider: up.TileCollider } {
    var map = try up.TileMap.loadTiled(allocator, "examples/assets/platformer.tmj");
    errdefer map.deinit();
    var collider = up.TileCollider.init(allocator);
    errdefer collider.deinit();
    try collider.addLayer(&map, 0);
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
    for (replay.frames) |frame| _ = game.step(&fixture.collider, .{ .left = (frame.buttons & 1) != 0, .right = (frame.buttons & 2) != 0, .jump = (frame.buttons & 4) != 0 }, 1.0 / @as(f32, @floatFromInt(replay.fixed_hz)));
    const hash = replayHash(game);
    try std.testing.expectEqual(@as(u64, 0xe4499432c1aab5be), hash);
}

fn replayHash(game: Game) u64 {
    var hash = std.hash.Fnv1a_64.init();
    hash.update(std.mem.asBytes(&game.controller.bounds.x));
    hash.update(std.mem.asBytes(&game.controller.bounds.y));
    hash.update(std.mem.asBytes(&game.velocity.x));
    hash.update(std.mem.asBytes(&game.velocity.y));
    hash.update(&.{ @intFromBool(game.controller.grounded), @intFromBool(game.controller.wall_left), @intFromBool(game.controller.wall_right), @intFromBool(game.controller.ceiling) });
    return hash.final();
}
