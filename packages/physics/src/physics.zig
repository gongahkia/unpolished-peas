const std = @import("std");
const c = @cImport({
    @cInclude("box2d/box2d.h");
});

pub fn physics(comptime up: type) type {
    return struct {
        pub const Config = struct {
            allocator: std.mem.Allocator = std.heap.page_allocator,
            gravity: up.Vec2 = .{ .x = 0, .y = 9.8 },
        };

        pub const BodyType = enum { static, kinematic, dynamic };
        pub const BodyHandle = struct { index: u32, generation: u32 };
        pub const FixtureHandle = struct { index: u32, generation: u32 };
        pub const JointHandle = struct { index: u32, generation: u32 };

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

        pub const BoxConfig = struct {
            size: up.Vec2,
            density: f32 = 1,
            sensor: bool = false,
            contact_events: bool = true,
        };

        pub const Events = struct {
            contact_begins: u32,
            contact_ends: u32,
            contact_hits: u32,
            sensor_begins: u32,
            sensor_ends: u32,
        };

        pub const World = struct {
            allocator: std.mem.Allocator,
            id: c.b2WorldId,
            bodies: std.ArrayList(BodySlot) = .empty,
            fixtures: std.ArrayList(FixtureSlot) = .empty,
            joints: std.ArrayList(JointSlot) = .empty,

            const BodySlot = struct { id: c.b2BodyId, generation: u32 = 1, live: bool = true };
            const FixtureShape = union(enum) { circle: f32, box: up.Vec2 };
            const FixtureSlot = struct { id: c.b2ShapeId, body: BodyHandle, shape: FixtureShape, generation: u32 = 1, live: bool = true };
            const JointSlot = struct { id: c.b2JointId, a: BodyHandle, b: BodyHandle, generation: u32 = 1, live: bool = true };

            pub fn init(config: Config) World {
                var definition = c.b2DefaultWorldDef();
                definition.gravity = .{ .x = config.gravity.x, .y = config.gravity.y };
                return .{ .allocator = config.allocator, .id = c.b2CreateWorld(&definition) };
            }

            pub fn deinit(self: *World) void {
                if (c.b2World_IsValid(self.id)) c.b2DestroyWorld(self.id);
                self.bodies.deinit(self.allocator);
                self.fixtures.deinit(self.allocator);
                self.joints.deinit(self.allocator);
                self.* = undefined;
            }

            pub fn step(self: World, dt: f32, sub_steps: u8) !void {
                if (!c.b2World_IsValid(self.id)) return error.StaleWorld;
                if (!std.math.isFinite(dt) or dt <= 0 or sub_steps == 0) return error.InvalidStep;
                c.b2World_Step(self.id, dt, sub_steps);
            }

            pub fn gravity(self: World) up.Vec2 {
                const value = c.b2World_GetGravity(self.id);
                return .{ .x = value.x, .y = value.y };
            }

            pub fn createBody(self: *World, config: BodyConfig) !BodyHandle {
                if (!c.b2World_IsValid(self.id)) return error.StaleWorld;
                if (!finiteVec(config.position)) return error.InvalidBody;
                var definition = c.b2DefaultBodyDef();
                definition.type = switch (config.body_type) {
                    .static => c.b2_staticBody,
                    .kinematic => c.b2_kinematicBody,
                    .dynamic => c.b2_dynamicBody,
                };
                definition.position = .{ .x = config.position.x, .y = config.position.y };
                const id = c.b2CreateBody(self.id, &definition);
                errdefer c.b2DestroyBody(id);
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
                for (self.joints.items) |*joint| if ((joint.a.index == handle.index and joint.a.generation == handle.generation) or (joint.b.index == handle.index and joint.b.generation == handle.generation)) {
                    joint.live = false;
                    joint.generation +%= 1;
                };
            }

            pub fn createCircle(self: *World, body: BodyHandle, config: CircleConfig) !FixtureHandle {
                if (!std.math.isFinite(config.radius) or !std.math.isFinite(config.density) or config.radius <= 0 or config.density < 0) return error.InvalidFixture;
                const body_slot = try self.bodySlot(body);
                var definition = fixtureDefinition(config.density, config.sensor, config.contact_events);
                const circle = c.b2Circle{ .center = .{ .x = 0, .y = 0 }, .radius = config.radius };
                const id = c.b2CreateCircleShape(body_slot.id, &definition, &circle);
                errdefer c.b2DestroyShape(id, true);
                try self.fixtures.append(self.allocator, .{ .id = id, .body = body, .shape = .{ .circle = config.radius } });
                return .{ .index = @intCast(self.fixtures.items.len - 1), .generation = 1 };
            }

            pub fn createBox(self: *World, body: BodyHandle, config: BoxConfig) !FixtureHandle {
                if (!finiteVec(config.size) or !std.math.isFinite(config.density) or config.size.x <= 0 or config.size.y <= 0 or config.density < 0) return error.InvalidFixture;
                const body_slot = try self.bodySlot(body);
                var definition = fixtureDefinition(config.density, config.sensor, config.contact_events);
                const box = c.b2MakeBox(config.size.x / 2, config.size.y / 2);
                const id = c.b2CreatePolygonShape(body_slot.id, &definition, &box);
                errdefer c.b2DestroyShape(id, true);
                try self.fixtures.append(self.allocator, .{ .id = id, .body = body, .shape = .{ .box = config.size } });
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
                if (!std.math.isFinite(length) or length <= 0) return error.InvalidJoint;
                var definition = c.b2DefaultDistanceJointDef();
                definition.bodyIdA = (try self.bodySlot(a)).id;
                definition.bodyIdB = (try self.bodySlot(b)).id;
                definition.length = length;
                const id = c.b2CreateDistanceJoint(self.id, &definition);
                errdefer c.b2DestroyJoint(id);
                try self.joints.append(self.allocator, .{ .id = id, .a = a, .b = b });
                return .{ .index = @intCast(self.joints.items.len - 1), .generation = 1 };
            }

            pub fn destroyJoint(self: *World, handle: JointHandle) !void {
                const slot = try self.jointSlot(handle);
                c.b2DestroyJoint(slot.id);
                slot.live = false;
                slot.generation +%= 1;
            }

            pub fn events(self: World) !Events {
                if (!c.b2World_IsValid(self.id)) return error.StaleWorld;
                const contacts = c.b2World_GetContactEvents(self.id);
                const sensors = c.b2World_GetSensorEvents(self.id);
                return .{ .contact_begins = @intCast(@max(contacts.beginCount, 0)), .contact_ends = @intCast(@max(contacts.endCount, 0)), .contact_hits = @intCast(@max(contacts.hitCount, 0)), .sensor_begins = @intCast(@max(sensors.beginCount, 0)), .sensor_ends = @intCast(@max(sensors.endCount, 0)) };
            }

            pub fn inspectorState(self: World) !up.InspectorPhysicsState {
                const contact_events = try self.events();
                var bodies: u32 = 0;
                var fixtures: u32 = 0;
                var joints: u32 = 0;
                for (self.bodies.items) |body| if (body.live) {
                    bodies += 1;
                };
                for (self.fixtures.items) |fixture| if (fixture.live) {
                    fixtures += 1;
                };
                for (self.joints.items) |joint| if (joint.live) {
                    joints += 1;
                };
                return .{ .bodies = bodies, .fixtures = fixtures, .joints = joints, .contact_begins = contact_events.contact_begins, .contact_ends = contact_events.contact_ends, .contact_hits = contact_events.contact_hits, .sensor_begins = contact_events.sensor_begins, .sensor_ends = contact_events.sensor_ends };
            }

            pub fn appendDebug(self: *World, commands: *up.RenderCommandBuffer, camera: *const up.Camera2D, canvas_size: up.Vec2) !void {
                if (!c.b2World_IsValid(self.id)) return error.StaleWorld;
                const viewport = camera.canvasViewport(canvas_size);
                try commands.append(.{ .push_clip = .{ .x = @intFromFloat(@floor(viewport.x)), .y = @intFromFloat(@floor(viewport.y)), .w = @max(0, @as(i32, @intFromFloat(@ceil(viewport.w)))), .h = @max(0, @as(i32, @intFromFloat(@ceil(viewport.h)))) } });
                errdefer _ = commands.append(.pop_clip) catch {};
                for (self.fixtures.items) |fixture| {
                    if (!fixture.live) continue;
                    const transform = c.b2Body_GetTransform((try self.bodySlot(fixture.body)).id);
                    switch (fixture.shape) {
                        .circle => |radius| try appendCircle(commands, camera, canvas_size, .{ .x = transform.p.x, .y = transform.p.y }, radius),
                        .box => |size| try appendBox(commands, camera, canvas_size, transform, size),
                    }
                }
                for (self.joints.items) |joint| {
                    if (!joint.live) continue;
                    const a = c.b2Body_GetPosition((try self.bodySlot(joint.a)).id);
                    const b = c.b2Body_GetPosition((try self.bodySlot(joint.b)).id);
                    const start = camera.worldToCanvas(.{ .x = a.x, .y = a.y }, canvas_size);
                    const end = camera.worldToCanvas(.{ .x = b.x, .y = b.y }, canvas_size);
                    try commands.append(.{ .line = .{ .x0 = @intFromFloat(@round(start.x)), .y0 = @intFromFloat(@round(start.y)), .x1 = @intFromFloat(@round(end.x)), .y1 = @intFromFloat(@round(end.y)), .color = up.Color.rgb(255, 198, 74) } });
                }
                try commands.append(.pop_clip);
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

            fn jointSlot(self: *World, handle: JointHandle) !*JointSlot {
                if (handle.index >= self.joints.items.len) return error.StaleJoint;
                const slot = &self.joints.items[handle.index];
                if (!slot.live or slot.generation != handle.generation or !c.b2Joint_IsValid(slot.id)) return error.StaleJoint;
                return slot;
            }
        };

        fn fixtureDefinition(density: f32, sensor: bool, contact_events: bool) c.b2ShapeDef {
            var definition = c.b2DefaultShapeDef();
            definition.density = density;
            definition.isSensor = sensor;
            definition.enableSensorEvents = sensor;
            definition.enableContactEvents = contact_events and !sensor;
            return definition;
        }

        fn finiteVec(value: up.Vec2) bool {
            return std.math.isFinite(value.x) and std.math.isFinite(value.y);
        }

        fn appendCircle(commands: *up.RenderCommandBuffer, camera: *const up.Camera2D, canvas_size: up.Vec2, center: up.Vec2, radius: f32) !void {
            const screen = camera.worldToCanvas(center, canvas_size);
            try commands.append(.{ .circle = .{ .x = @intFromFloat(@round(screen.x)), .y = @intFromFloat(@round(screen.y)), .radius = @max(1, @as(i32, @intFromFloat(@round(radius * camera.zoom)))), .color = up.Color.rgb(90, 220, 255) } });
        }

        fn appendBox(commands: *up.RenderCommandBuffer, camera: *const up.Camera2D, canvas_size: up.Vec2, transform: c.b2Transform, size: up.Vec2) !void {
            const local = [_]up.Vec2{ .{ .x = -size.x / 2, .y = -size.y / 2 }, .{ .x = size.x / 2, .y = -size.y / 2 }, .{ .x = size.x / 2, .y = size.y / 2 }, .{ .x = -size.x / 2, .y = size.y / 2 } };
            var points: [4]up.Vec2 = undefined;
            for (local, 0..) |point, index| points[index] = camera.worldToCanvas(.{ .x = transform.p.x + transform.q.c * point.x - transform.q.s * point.y, .y = transform.p.y + transform.q.s * point.x + transform.q.c * point.y }, canvas_size);
            const color = up.Color.rgb(90, 220, 255);
            try commands.append(.{ .triangle = .{ .a = points[0], .b = points[1], .c = points[2], .color = color } });
            try commands.append(.{ .triangle = .{ .a = points[0], .b = points[2], .c = points[3], .color = color } });
        }
    };
}
