const up = @import("unpolished-peas");

pub fn ballAtlas(allocator: @import("std").mem.Allocator, image: up.assets.Image) !up.assets.Atlas {
    return up.assets.Atlas.init(allocator, try image.clone(allocator), "ball.png", &.{
        .{ .name = "tile_a", .x = 0, .y = 0, .w = 8, .h = 8 },
        .{ .name = "tile_b", .x = 8, .y = 0, .w = 8, .h = 8 },
        .{ .name = "tile_c", .x = 0, .y = 8, .w = 8, .h = 8 },
        .{ .name = "tile_d", .x = 8, .y = 8, .w = 8, .h = 8 },
    }, &.{.{ .name = "pulse", .frames = &.{ .{ .frame = "tile_a", .duration = 0.12 }, .{ .frame = "tile_b", .duration = 0.12 }, .{ .frame = "tile_d", .duration = 0.12 }, .{ .frame = "tile_c", .duration = 0.12 } } }});
}
