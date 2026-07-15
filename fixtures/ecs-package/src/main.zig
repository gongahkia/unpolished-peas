const std = @import("std");
const core = @import("unpolished-peas").api;
const ecs = @import("unpolished-peas-ecs");

test "ECS package sparse stores and commands remain deterministic" {
    const position = core.Vec2{ .x = 1, .y = 2 };
    try std.testing.expectEqual(@as(f32, 2), position.y);
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    var values = ecs.ComponentStore(u8).init(std.testing.allocator);
    defer values.deinit();
    const first = try world.create();
    const second = try world.create();
    try values.put(&world, second, 2);
    try values.put(&world, first, 1);
    const entities = try values.entities(&world, std.testing.allocator);
    defer std.testing.allocator.free(entities);
    try std.testing.expectEqualSlices(ecs.Entity, &.{ first, second }, entities);
    var commands = ecs.Commands.init(std.testing.allocator);
    defer commands.deinit();
    try commands.destroy(first);
    try commands.apply(&world);
    try std.testing.expectError(error.StaleEntity, world.validate(first));
    try std.testing.expectEqual(@as(u8, 2), (try values.get(&world, second)).*);
}
