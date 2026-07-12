const up = @import("unpolished-peas");
const c = @cImport({
    @cInclude("box2d/box2d.h");
});

pub const Config = struct {
    gravity: up.Vec2 = .{ .x = 0, .y = 9.8 },
};

pub const World = struct {
    id: c.b2WorldId,

    pub fn init(config: Config) World {
        var definition = c.b2DefaultWorldDef();
        definition.gravity = .{ .x = config.gravity.x, .y = config.gravity.y };
        return .{ .id = c.b2CreateWorld(&definition) };
    }

    pub fn deinit(self: *World) void {
        if (c.b2World_IsValid(self.id)) c.b2DestroyWorld(self.id);
        self.* = undefined;
    }

    pub fn step(self: World, dt: f32, sub_steps: u8) !void {
        if (!c.b2World_IsValid(self.id)) return error.StaleWorld;
        if (dt <= 0 or sub_steps == 0) return error.InvalidStep;
        c.b2World_Step(self.id, dt, sub_steps);
    }

    pub fn gravity(self: World) up.Vec2 {
        const value = c.b2World_GetGravity(self.id);
        return .{ .x = value.x, .y = value.y };
    }
};

test "Box2D world creates steps and destroys cleanly" {
    var world = World.init(.{ .gravity = .{ .x = 0, .y = 4 } });
    defer world.deinit();
    try world.step(1.0 / 60.0, 4);
    try @import("std").testing.expectEqual(up.Vec2.init(0, 4), world.gravity());
}
