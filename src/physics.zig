const std = @import("std");
const up = @import("unpolished-peas");
const c = @cImport({
    @cInclude("box2d/box2d.h");
});

pub const Config = struct {
    allocator: std.mem.Allocator = std.heap.page_allocator,
    gravity: up.Vec2 = .{ .x = 0, .y = 9.8 },
};

pub const BodyType = enum { static, kinematic, dynamic };
pub const BodyHandle = struct { index: u32, generation: u32 };
pub const FixtureHandle = struct { index: u32, generation: u32 };
pub const JointHandle = struct { id: c.b2JointId };

pub const BodyConfig = struct {
    body_type: BodyType = .static,
    position: up.Vec2 = .{},
};

pub const CircleConfig = struct {
    radius: f32,
    density: f32 = 1,
    sensor: bool = false,
    contact_events: bool = true,
};

pub const Events = struct {
    contact_begins: u32,
    contact_ends: u32,
    sensor_begins: u32,
    sensor_ends: u32,
};

pub const World = struct {
    allocator: std.mem.Allocator,
    id: c.b2WorldId,
    bodies: std.ArrayList(BodySlot) = .empty,
    fixtures: std.ArrayList(FixtureSlot) = .empty,

    const BodySlot = struct { id: c.b2BodyId, generation: u32 = 1, live: bool = true };
    const FixtureSlot = struct { id: c.b2ShapeId, body: BodyHandle, generation: u32 = 1, live: bool = true };

    pub fn init(config: Config) World {
        var definition = c.b2DefaultWorldDef();
        definition.gravity = .{ .x = config.gravity.x, .y = config.gravity.y };
        return .{ .allocator = config.allocator, .id = c.b2CreateWorld(&definition) };
    }

    pub fn deinit(self: *World) void {
        if (c.b2World_IsValid(self.id)) c.b2DestroyWorld(self.id);
        self.bodies.deinit(self.allocator);
        self.fixtures.deinit(self.allocator);
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

    pub fn createBody(self: *World, config: BodyConfig) !BodyHandle {
        if (!c.b2World_IsValid(self.id)) return error.StaleWorld;
        var definition = c.b2DefaultBodyDef();
        definition.type = switch (config.body_type) {
            .static => c.b2_staticBody,
            .kinematic => c.b2_kinematicBody,
            .dynamic => c.b2_dynamicBody,
        };
        definition.position = .{ .x = config.position.x, .y = config.position.y };
        const id = c.b2CreateBody(self.id, &definition);
        try self.bodies.append(self.allocator, .{ .id = id });
        return .{ .index = @intCast(self.bodies.items.len - 1), .generation = 1 };
    }

    pub fn destroyBody(self: *World, handle: BodyHandle) !void {
        const slot = try self.bodySlot(handle);
        c.b2DestroyBody(slot.id);
        slot.live = false;
        slot.generation +%= 1;
        for (self.fixtures.items) |*fixture| if (fixture.body.index == handle.index and fixture.body.generation == handle.generation) {
            fixture.live = false;
            fixture.generation +%= 1;
        };
    }

    pub fn createCircle(self: *World, body: BodyHandle, config: CircleConfig) !FixtureHandle {
        if (config.radius <= 0 or config.density < 0) return error.InvalidFixture;
        const body_slot = try self.bodySlot(body);
        var definition = c.b2DefaultShapeDef();
        definition.density = config.density;
        definition.isSensor = config.sensor;
        definition.enableSensorEvents = config.sensor;
        definition.enableContactEvents = config.contact_events and !config.sensor;
        const circle = c.b2Circle{ .center = .{ .x = 0, .y = 0 }, .radius = config.radius };
        const id = c.b2CreateCircleShape(body_slot.id, &definition, &circle);
        try self.fixtures.append(self.allocator, .{ .id = id, .body = body });
        return .{ .index = @intCast(self.fixtures.items.len - 1), .generation = 1 };
    }

    pub fn destroyFixture(self: *World, handle: FixtureHandle) !void {
        const slot = try self.fixtureSlot(handle);
        c.b2DestroyShape(slot.id, true);
        slot.live = false;
        slot.generation +%= 1;
    }

    pub fn bodyPosition(self: *World, handle: BodyHandle) !up.Vec2 {
        const value = c.b2Body_GetPosition((try self.bodySlot(handle)).id);
        return .{ .x = value.x, .y = value.y };
    }

    pub fn createDistanceJoint(self: *World, a: BodyHandle, b: BodyHandle, length: f32) !JointHandle {
        if (length <= 0) return error.InvalidJoint;
        var definition = c.b2DefaultDistanceJointDef();
        definition.bodyIdA = (try self.bodySlot(a)).id;
        definition.bodyIdB = (try self.bodySlot(b)).id;
        definition.length = length;
        return .{ .id = c.b2CreateDistanceJoint(self.id, &definition) };
    }

    pub fn events(self: World) !Events {
        if (!c.b2World_IsValid(self.id)) return error.StaleWorld;
        const contacts = c.b2World_GetContactEvents(self.id);
        const sensors = c.b2World_GetSensorEvents(self.id);
        return .{ .contact_begins = @intCast(@max(contacts.beginCount, 0)), .contact_ends = @intCast(@max(contacts.endCount, 0)), .sensor_begins = @intCast(@max(sensors.beginCount, 0)), .sensor_ends = @intCast(@max(sensors.endCount, 0)) };
    }

    fn bodySlot(self: *World, handle: BodyHandle) !*BodySlot {
        if (handle.index >= self.bodies.items.len) return error.StaleBody;
        const slot = &self.bodies.items[handle.index];
        if (!slot.live or slot.generation != handle.generation or !c.b2Body_IsValid(slot.id)) return error.StaleBody;
        return slot;
    }

    fn fixtureSlot(self: *World, handle: FixtureHandle) !*FixtureSlot {
        if (handle.index >= self.fixtures.items.len) return error.StaleFixture;
        const slot = &self.fixtures.items[handle.index];
        if (!slot.live or slot.generation != handle.generation or !c.b2Shape_IsValid(slot.id)) return error.StaleFixture;
        return slot;
    }
};

test "Box2D world creates steps and destroys cleanly" {
    var world = World.init(.{ .gravity = .{ .x = 0, .y = 4 } });
    defer world.deinit();
    try world.step(1.0 / 60.0, 4);
    try @import("std").testing.expectEqual(up.Vec2.init(0, 4), world.gravity());
}

test "Box2D body and fixture handles reject stale access" {
    var world = World.init(.{});
    defer world.deinit();
    const body = try world.createBody(.{ .body_type = .dynamic });
    const fixture = try world.createCircle(body, .{ .radius = 1, .sensor = true });
    try world.destroyBody(body);
    try std.testing.expectError(error.StaleBody, world.bodyPosition(body));
    try std.testing.expectError(error.StaleFixture, world.destroyFixture(fixture));
}

test "Box2D distance joints and event snapshots are available" {
    var world = World.init(.{});
    defer world.deinit();
    const a = try world.createBody(.{ .body_type = .dynamic });
    const b = try world.createBody(.{ .body_type = .dynamic, .position = .{ .x = 2, .y = 0 } });
    _ = try world.createDistanceJoint(a, b, 2);
    try world.step(1.0 / 60.0, 4);
    _ = try world.events();
}
