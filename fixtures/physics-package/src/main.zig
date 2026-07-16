const std = @import("std");
const core = @import("unpolished-peas");
const physics = core.physics;

test "physics package owns Box2D lifecycle and stale handles" {
    var world = physics.World.init(.{ .gravity = .{ .x = 0, .y = 4 } });
    defer world.deinit();
    const body = try world.createBody(.{ .body_type = .dynamic });
    const fixture = try world.createCircle(body, .{ .radius = 1, .sensor = true });
    try world.step(1.0 / 60.0, 4);
    try std.testing.expectEqual(core.Vec2.init(0, 4), world.gravity());
    try world.destroyBody(body);
    try std.testing.expectError(error.StaleBody, world.bodyPosition(body));
    try std.testing.expectError(error.StaleFixture, world.destroyFixture(fixture));
}

test "physics package emits core debug commands" {
    var world = physics.World.init(.{});
    defer world.deinit();
    const ground = try world.createBody(.{});
    _ = try world.createBox(ground, .{ .size = .{ .x = 4, .y = 2 } });
    const body = try world.createBody(.{ .body_type = .dynamic, .position = .{ .x = 0, .y = -0.5 } });
    _ = try world.createCircle(body, .{ .radius = 1 });
    try world.step(1.0 / 60.0, 4);
    try std.testing.expect((try world.events()).contact_begins > 0);
    var commands = core.RenderCommandBuffer.init(std.testing.allocator);
    defer commands.deinit();
    var camera = core.Camera2D{};
    try world.appendDebug(&commands, &camera, .{ .x = 16, .y = 16 });
    var canvas = try core.Canvas.init(std.testing.allocator, 16, 16);
    defer canvas.deinit();
    var renderer = core.HeadlessRenderer.init(std.testing.allocator, &canvas);
    defer renderer.deinit();
    try renderer.submit(commands.commands.items);
    try std.testing.expect(!std.meta.eql(canvas.get(8, 8).?, core.Color.transparent));
}

test "physics worlds own inspector state and teardown independently" {
    var first = physics.World.init(.{ .allocator = std.testing.allocator });
    defer first.deinit();
    var second = physics.World.init(.{ .allocator = std.testing.allocator });
    defer second.deinit();
    const a = try first.createBody(.{ .body_type = .dynamic });
    const b = try first.createBody(.{ .body_type = .dynamic, .position = .{ .x = 2, .y = 0 } });
    _ = try first.createCircle(a, .{ .radius = 1 });
    _ = try first.createDistanceJoint(a, b, 2);
    const before = try first.inspectorState();
    const again = try first.inspectorState();
    try std.testing.expectEqual(before, again);
    try std.testing.expectEqual(@as(u32, 2), before.bodies);
    try std.testing.expectEqual(@as(u32, 1), before.fixtures);
    try std.testing.expectEqual(@as(u32, 1), before.joints);
    try second.step(1.0 / 60.0, 1);
}
