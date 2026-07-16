const std = @import("std");
const up = @import("unpolished-peas");
const ecs = up.ecs;

test "downstream module imports remain SDL-free" {
    var canvas = try up.Canvas.init(std.testing.allocator, 1, 1);
    defer canvas.deinit();
}

test "ECS remains independently consumable" {
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    const entity = try world.create();
    try world.validate(entity);
}
