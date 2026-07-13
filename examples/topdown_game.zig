const std = @import("std");
const up = @import("unpolished-peas");

pub const width = 160;
pub const height = 96;
pub const actions = [_]up.Action{
    .{ .name = "left", .binding = .{ .key = .left } },
    .{ .name = "right", .binding = .{ .key = .right } },
    .{ .name = "up", .binding = .{ .key = .up } },
    .{ .name = "down", .binding = .{ .key = .down } },
    .{ .name = "fire", .binding = .{ .key = .action } },
};

pub const Event = struct { fired: bool = false };
pub const Game = struct {
    player: up.Vec2 = .{ .x = 80, .y = 48 },
    aim: up.Vec2 = .{ .x = 1, .y = 0 },
    shots: u32 = 0,

    pub fn step(self: *Game, input: up.Input, dt: f32) Event {
        const bindings = up.ActionMap{ .actions = &actions };
        var move = up.Vec2{ .x = bindings.value(input, "game", "right") - bindings.value(input, "game", "left"), .y = bindings.value(input, "game", "down") - bindings.value(input, "game", "up") };
        if (move.lenSq() > 1) move = move.normalized();
        if (move.lenSq() > 0) self.aim = move;
        self.player = self.player.add(move.scale(56 * dt));
        self.player.x = std.math.clamp(self.player.x, 12, 148);
        self.player.y = std.math.clamp(self.player.y, 12, 84);
        if (bindings.value(input, "game", "fire") == 0) return .{};
        self.shots += 1;
        return .{ .fired = true };
    }
};

test "top-down action map drives deterministic bounded movement" {
    var input = up.Input{};
    input.set(.right, true);
    input.set(.down, true);
    var a = Game{};
    var b = Game{};
    var frame: u32 = 0;
    while (frame < 120) : (frame += 1) {
        _ = a.step(input, 1.0 / 60.0);
        _ = b.step(input, 1.0 / 60.0);
    }
    try std.testing.expectEqualDeep(a, b);
    try std.testing.expect(a.player.x > 80 and a.player.y > 48);
    input.set(.action, true);
    try std.testing.expect(a.step(input, 1.0 / 60.0).fired);
}
