const std = @import("std");
const map_source = @import("map_source.zig");
const tilemap = @import("tilemap.zig");

pub fn encode(allocator: std.mem.Allocator, map: tilemap.TileMap, name: []const u8, diagnostic: *map_source.Diagnostic) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const cwd = try std.process.getCwdAlloc(arena.allocator());
    const source = try convert(arena.allocator(), map, name, cwd);
    const encoded = try source.encode(allocator);
    errdefer allocator.free(encoded);
    var parsed = try map_source.parse(allocator, encoded, diagnostic);
    parsed.deinit(allocator);
    return encoded;
}

fn convert(allocator: std.mem.Allocator, map: tilemap.TileMap, name: []const u8, cwd: []const u8) !map_source.Source {
    const tilesets = try allocator.alloc(map_source.TileSet, map.tilesets.items.len);
    for (map.tilesets.items, 0..) |tileset, index| {
        tilesets[index] = .{
            .id = tileset.name,
            .kind = switch (tileset.kind) {
                .grid_image => .grid_image,
                .image_collection => .image_collection,
                .atlas_frames => .atlas_frames,
            },
            .path = try nativePath(allocator, cwd, tileset.path),
            .tile_width = tileset.tile_size.x,
            .tile_height = tileset.tile_size.y,
            .margin = tileset.margin,
            .spacing = tileset.spacing,
            .image_paths = try convertImagePaths(allocator, cwd, tileset.image_paths),
            .atlas_frames = tileset.atlas_frames,
            .animations = try convertAnimations(allocator, tileset.animations),
        };
    }
    const layers = try allocator.alloc(map_source.Layer, map.layers.items.len);
    for (map.layers.items, 0..) |layer, index| {
        layers[index] = .{
            .id = try layerId(allocator, index),
            .name = layer.name,
            .kind = switch (layer.kind) {
                .tiles => .tiles,
                .int_grid => .int_grid,
                .group => .group,
                .objects => .objects,
            },
            .parent = if (layer.parent) |parent| try layerId(allocator, parent) else null,
            .visible = layer.visible,
            .opacity = layer.opacity,
            .offset_x = layer.offset.x,
            .offset_y = layer.offset.y,
            .parallax_x = layer.parallax.x,
            .parallax_y = layer.parallax.y,
            .cells = try convertCells(allocator, map, layer),
            .objects = try convertObjects(allocator, layer.objects.items),
            .properties = try convertProperties(allocator, layer.properties),
        };
    }
    return .{
        .format = map_source.native_format,
        .version = map_source.native_version,
        .metadata = .{
            .name = name,
            .projection = switch (map.projection) {
                .orthogonal => .orthogonal,
                .isometric => .isometric,
            },
            .tile_width = map.tile_size.x,
            .tile_height = map.tile_size.y,
            .chunk_size = map.chunk_size,
        },
        .tilesets = tilesets,
        .layers = layers,
    };
}

fn convertImagePaths(allocator: std.mem.Allocator, cwd: []const u8, image_paths: []const ?[]u8) ![]const ?[]const u8 {
    const output = try allocator.alloc(?[]const u8, image_paths.len);
    for (image_paths, 0..) |image_path, index| output[index] = if (image_path) |path| try nativePath(allocator, cwd, path) else null;
    return output;
}

fn convertAnimations(allocator: std.mem.Allocator, animations: []const tilemap.TileAnimation) ![]const map_source.Animation {
    const output = try allocator.alloc(map_source.Animation, animations.len);
    for (animations, 0..) |animation, index| {
        const frames = try allocator.alloc(map_source.AnimationFrame, animation.frames.len);
        for (animation.frames, 0..) |frame, frame_index| frames[frame_index] = .{ .tile_id = frame.tile_id, .duration = frame.duration };
        output[index] = .{ .tile_id = animation.tile_id, .frames = frames };
    }
    std.mem.sort(map_source.Animation, output, {}, struct {
        fn less(_: void, left: map_source.Animation, right: map_source.Animation) bool {
            return left.tile_id < right.tile_id;
        }
    }.less);
    return output;
}

fn nativePath(allocator: std.mem.Allocator, cwd: []const u8, path: []const u8) ![]const u8 {
    const resolved = try std.fs.path.resolve(allocator, &.{ cwd, path });
    const relative = try std.fs.path.relative(allocator, cwd, resolved);
    if (!safePath(relative)) return error.UnsafeAssetPath;
    return relative;
}

fn safePath(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return false;
    var components = std.mem.tokenizeAny(u8, path, "/\\");
    while (components.next()) |component| if (std.mem.eql(u8, component, "..")) return false;
    return true;
}

fn layerId(allocator: std.mem.Allocator, index: usize) ![]const u8 {
    return std.fmt.allocPrint(allocator, "layer-{d}", .{index});
}

fn convertCells(allocator: std.mem.Allocator, map: tilemap.TileMap, layer: tilemap.TileMapLayer) ![]const map_source.Cell {
    if (layer.kind != .tiles and layer.kind != .int_grid) return &.{};
    var cells = std.ArrayListUnmanaged(map_source.Cell){};
    for (layer.chunks.items) |chunk| {
        for (chunk.tiles, 0..) |stack, index| {
            if (layer.kind == .tiles and stack.items.items.len == 0) continue;
            const size: i32 = @intCast(map.chunk_size);
            const x = chunk.coord.x * size + @as(i32, @intCast(index % map.chunk_size));
            const y = chunk.coord.y * size + @as(i32, @intCast(index / map.chunk_size));
            const tiles = if (layer.kind == .tiles) try convertTiles(allocator, map, stack.items.items) else &.{};
            try cells.append(allocator, .{
                .x = x,
                .y = y,
                .tiles = tiles,
                .int_grid = if (layer.kind == .int_grid) chunk.int_grid[index] else null,
            });
        }
    }
    std.mem.sort(map_source.Cell, cells.items, {}, lessCell);
    return cells.toOwnedSlice(allocator);
}

fn lessCell(_: void, left: map_source.Cell, right: map_source.Cell) bool {
    return left.y < right.y or (left.y == right.y and left.x < right.x);
}

fn convertTiles(allocator: std.mem.Allocator, map: tilemap.TileMap, tiles: []const tilemap.Tile) ![]const map_source.Tile {
    const output = try allocator.alloc(map_source.Tile, tiles.len);
    for (tiles, 0..) |tile, index| {
        output[index] = .{
            .tileset = map.tilesets.items[tile.tileset].name,
            .id = tile.id,
            .flip_x = tile.flags.flip_x,
            .flip_y = tile.flags.flip_y,
            .diagonal = tile.flags.diagonal,
            .opacity = tile.opacity,
        };
    }
    return output;
}

fn convertObjects(allocator: std.mem.Allocator, objects: []const tilemap.MapObject) ![]const map_source.Object {
    const output = try allocator.alloc(map_source.Object, objects.len);
    for (objects, 0..) |object, index| {
        const shape: map_source.Shape = switch (object.shape) {
            .rectangle => .rectangle,
            .ellipse => .ellipse,
            .point => .point,
            .polygon => .polygon,
            .polyline => .polyline,
        };
        output[index] = .{
            .id = try std.fmt.allocPrint(allocator, "{d}", .{object.id}),
            .name = object.name,
            .class_name = object.class_name,
            .x = object.bounds.x,
            .y = object.bounds.y,
            .width = object.bounds.w,
            .height = object.bounds.h,
            .shape = shape,
            .points = try convertPoints(allocator, object.shape),
            .properties = try convertProperties(allocator, object.properties),
        };
    }
    return output;
}

fn convertPoints(allocator: std.mem.Allocator, shape: tilemap.ObjectShape) ![]const map_source.Point {
    const runtime_points = switch (shape) {
        .polygon => |points| points,
        .polyline => |points| points,
        else => return &.{},
    };
    const points = try allocator.alloc(map_source.Point, runtime_points.len);
    for (runtime_points, 0..) |point, index| points[index] = .{ .x = point.x, .y = point.y };
    return points;
}

fn convertProperties(allocator: std.mem.Allocator, properties: []const tilemap.Property) ![]const map_source.Property {
    const output = try allocator.alloc(map_source.Property, properties.len);
    for (properties, 0..) |property, index| {
        output[index] = .{ .name = property.name };
        switch (property.value) {
            .string => |value| output[index].string = value,
            .integer => |value| output[index].integer = value,
            .float => |value| output[index].float = value,
            .boolean => |value| output[index].boolean = value,
        }
    }
    return output;
}
