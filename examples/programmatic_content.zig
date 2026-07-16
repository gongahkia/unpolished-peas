const up = @import("unpolished-peas");

pub fn ballAtlas(allocator: @import("std").mem.Allocator, image: up.Image) !up.Atlas {
    return up.Atlas.init(allocator, try image.clone(allocator), "ball.png", &.{
        .{ .name = "tile_a", .x = 0, .y = 0, .w = 8, .h = 8 },
        .{ .name = "tile_b", .x = 8, .y = 0, .w = 8, .h = 8 },
        .{ .name = "tile_c", .x = 0, .y = 8, .w = 8, .h = 8 },
        .{ .name = "tile_d", .x = 8, .y = 8, .w = 8, .h = 8 },
    }, &.{.{ .name = "pulse", .frames = &.{ .{ .frame = "tile_a", .duration = 0.12 }, .{ .frame = "tile_b", .duration = 0.12 }, .{ .frame = "tile_d", .duration = 0.12 }, .{ .frame = "tile_c", .duration = 0.12 } } }});
}

pub fn topdownMap(allocator: @import("std").mem.Allocator) !up.TileMap {
    var map = try up.TileMap.init(allocator, .{ .x = 8, .y = 8 }, 32);
    errdefer map.deinit();
    _ = try map.addTileSet("orb", .grid_image, "ball.png", .{ .x = 8, .y = 8 });
    const layer = try map.addLayer("arena", .tiles, null);
    var x: i32 = 0;
    while (x < 8) : (x += 1) {
        try map.setTile(layer, .{ .x = x, .y = 0 }, .{ .tileset = 0, .id = 0 });
        try map.setTile(layer, .{ .x = x, .y = 5 }, .{ .tileset = 0, .id = 0 });
    }
    var y: i32 = 1;
    while (y < 5) : (y += 1) {
        try map.setTile(layer, .{ .x = 0, .y = y }, .{ .tileset = 0, .id = 0 });
        try map.setTile(layer, .{ .x = 7, .y = y }, .{ .tileset = 0, .id = 0 });
    }
    return map;
}

pub const PlatformerMap = struct {
    map: up.TileMap,
    collision_layer: u32,
};

pub fn platformerMap(allocator: @import("std").mem.Allocator) !PlatformerMap {
    var map = try up.TileMap.init(allocator, .{ .x = 8, .y = 8 }, 32);
    errdefer map.deinit();
    _ = try map.addTileSet("orb", .grid_image, "ball.png", .{ .x = 8, .y = 8 });
    const visual_layer = try map.addLayer("terrain", .tiles, null);
    const collision_layer = try map.addLayer("collision", .int_grid, null);
    var x: i32 = 0;
    while (x < 12) : (x += 1) {
        try map.setTile(visual_layer, .{ .x = x, .y = 5 }, .{ .tileset = 0, .id = 0 });
        try map.setIntGrid(collision_layer, .{ .x = x, .y = 5 }, 1);
    }
    try map.setTile(visual_layer, .{ .x = 2, .y = 3 }, .{ .tileset = 0, .id = 0 });
    try map.setTile(visual_layer, .{ .x = 2, .y = 4 }, .{ .tileset = 0, .id = 0 });
    try map.setIntGrid(collision_layer, .{ .x = 2, .y = 3 }, 1);
    try map.setIntGrid(collision_layer, .{ .x = 2, .y = 4 }, 1);
    return .{ .map = map, .collision_layer = collision_layer };
}
