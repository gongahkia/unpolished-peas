const std = @import("std");
const Camera2D = @import("camera.zig").Camera2D;
const CameraCanvas = @import("camera_canvas.zig").CameraCanvas;
const Canvas = @import("canvas.zig").Canvas;
const Color = @import("color.zig").Color;
const Image = @import("image.zig").Image;
const map_source = @import("map_source.zig");
const tilemap = @import("tilemap.zig");

const max_source_bytes = 64 * 1024 * 1024;

pub const Diagnostic = struct {
    line: usize = 1,
    column: usize = 1,
    message: []const u8 = "invalid Tiled map",
};

pub fn importFile(allocator: std.mem.Allocator, input_path: []const u8, diagnostic: *Diagnostic) ![]u8 {
    const input = std.fs.cwd().readFileAlloc(allocator, input_path, max_source_bytes) catch |err| {
        diagnostic.* = .{ .message = "unable to read Tiled source" };
        return err;
    };
    defer allocator.free(input);
    var map = tilemap.TileMap.loadTiled(allocator, input_path) catch |err| {
        setLoadDiagnostic(diagnostic, input, err);
        return err;
    };
    defer map.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const source = convert(arena.allocator(), map, input_path) catch |err| {
        setConversionDiagnostic(diagnostic, input, err);
        return err;
    };
    const encoded = try source.encode(allocator);
    errdefer allocator.free(encoded);
    var native_diagnostic = map_source.Diagnostic{};
    var parsed = map_source.parse(allocator, encoded, &native_diagnostic) catch {
        diagnostic.* = .{
            .line = native_diagnostic.line,
            .column = native_diagnostic.column,
            .message = native_diagnostic.message,
        };
        return error.InvalidTiledContent;
    };
    parsed.deinit(allocator);
    return encoded;
}

fn convert(allocator: std.mem.Allocator, map: tilemap.TileMap, input_path: []const u8) !map_source.Source {
    const cwd = try std.process.getCwdAlloc(allocator);
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
            .name = std.fs.path.stem(input_path),
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
    if (!safePath(relative)) return error.UnsafeTiledAssetPath;
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

fn setLoadDiagnostic(diagnostic: *Diagnostic, source: []const u8, err: anyerror) void {
    const detail = switch (err) {
        error.UnsupportedProjection => .{ "orientation", "unsupported projection; use orthogonal or isometric" },
        error.UnsupportedTiledImageLayer => .{ "imagelayer", "image layers are unsupported; use tile layers" },
        error.UnsupportedTiledLayer => .{ "\"type\"", "unsupported layer; use group, tilelayer, or objectgroup" },
        error.UnsupportedTiledProperty => .{ "\"type\"", "unsupported property; use string, file, int, object, float, or bool" },
        error.UnsupportedTiledEncoding => .{ "\"encoding\"", "unsupported layer encoding; use base64" },
        error.UnsupportedTiledCompression => .{ "\"compression\"", "unsupported layer compression; use zlib, gzip, or zstd" },
        else => .{ "", "invalid Tiled map; validate it in Tiled" },
    };
    const location = locationOf(source, detail[0]);
    diagnostic.* = .{ .line = location.line, .column = location.column, .message = detail[1] };
}

fn setConversionDiagnostic(diagnostic: *Diagnostic, source: []const u8, err: anyerror) void {
    const detail: struct { []const u8, []const u8 } = switch (err) {
        error.UnsafeTiledAssetPath => .{ "\"image\"", "asset path escapes the current directory; move it under the project" },
        else => .{ "", "Tiled map cannot be converted to native source" },
    };
    const location = locationOf(source, detail[0]);
    diagnostic.* = .{ .line = location.line, .column = location.column, .message = detail[1] };
}

fn locationOf(source: []const u8, needle: []const u8) struct { line: usize, column: usize } {
    const offset = std.mem.indexOf(u8, source, needle) orelse return .{ .line = 1, .column = 1 };
    var line: usize = 1;
    var column: usize = 1;
    for (source[0..offset]) |byte| {
        if (byte == '\n') {
            line += 1;
            column = 1;
        } else column += 1;
    }
    return .{ .line = line, .column = column };
}

test "imports the finite Tiled fixture to validated native source with equivalent rendering" {
    var diagnostic = Diagnostic{};
    const imported = try importFile(std.testing.allocator, "fixtures/tiled/v1/finite-embedded.tmj", &diagnostic);
    defer std.testing.allocator.free(imported);
    var source_diagnostic = map_source.Diagnostic{};
    var source = try map_source.parse(std.testing.allocator, imported, &source_diagnostic);
    defer source.deinit(std.testing.allocator);
    var native = try source.build(std.testing.allocator);
    defer native.deinit();
    var tiled = try tilemap.TileMap.loadTiled(std.testing.allocator, "fixtures/tiled/v1/finite-embedded.tmj");
    defer tiled.deinit();
    try std.testing.expectEqual(tiled.layers.items.len, native.layers.items.len);
    try std.testing.expectEqual(tiled.tileAt(1, .{ .x = 0, .y = 0 }).?.flags.flip_x, native.tileAt(1, .{ .x = 0, .y = 0 }).?.flags.flip_x);

    var pixels: [128]Color = undefined;
    for (&pixels, 0..) |*pixel, index| pixel.* = if (index % 16 < 8) Color.rgb(255, 0, 0) else Color.rgb(0, 255, 0);
    const image = Image{ .allocator = std.testing.allocator, .width = 16, .height = 8, .pixels = &pixels };
    var tiled_canvas = try Canvas.init(std.testing.allocator, 24, 16);
    defer tiled_canvas.deinit();
    var native_canvas = try Canvas.init(std.testing.allocator, 24, 16);
    defer native_canvas.deinit();
    tiled_canvas.clear(Color.black);
    native_canvas.clear(Color.black);
    const camera = Camera2D{ .position = .{ .x = 12, .y = 8 } };
    tiled.drawImagesAt(CameraCanvas.init(&tiled_canvas, &camera), &.{image}, 0.1);
    native.drawImagesAt(CameraCanvas.init(&native_canvas, &camera), &.{image}, 0.1);
    try std.testing.expectEqualSlices(Color, tiled_canvas.pixels, native_canvas.pixels);
}

test "imports external Tiled fixtures with signed cells" {
    var diagnostic = Diagnostic{};
    const imported = try importFile(std.testing.allocator, "fixtures/tiled/v1/infinite-external.tmj", &diagnostic);
    defer std.testing.allocator.free(imported);
    var source_diagnostic = map_source.Diagnostic{};
    var source = try map_source.parse(std.testing.allocator, imported, &source_diagnostic);
    defer source.deinit(std.testing.allocator);
    var native = try source.build(std.testing.allocator);
    defer native.deinit();
    const tile = native.tileAt(0, .{ .x = -1, .y = 2 }).?;
    try std.testing.expect(tile.flags.flip_x and tile.flags.flip_y and tile.flags.diagonal);
}

test "imports image-collection tile paths" {
    var diagnostic = Diagnostic{};
    const imported = try importFile(std.testing.allocator, "fixtures/tiled/v1/image-collection.tmj", &diagnostic);
    defer std.testing.allocator.free(imported);
    var source_diagnostic = map_source.Diagnostic{};
    var source = try map_source.parse(std.testing.allocator, imported, &source_diagnostic);
    defer source.deinit(std.testing.allocator);
    try std.testing.expectEqual(map_source.TileSourceKind.image_collection, source.tilesets[0].kind);
    try std.testing.expectEqual(@as(usize, 3), source.tilesets[0].image_paths.len);
    try std.testing.expect(source.tilesets[0].image_paths[1] == null);
    var native = try source.build(std.testing.allocator);
    defer native.deinit();
    try std.testing.expect(native.tilesets.items[0].image_paths[0] != null);
    try std.testing.expect(native.tilesets.items[0].image_paths[1] == null);
}

test "unsupported Tiled layers report their source location" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "unsupported.tmj", .data =
        \\{
        \\  "orientation": "orthogonal",
        \\  "tilewidth": 8,
        \\  "tileheight": 8,
        \\  "tilesets": [],
        \\  "layers": [{"type": "imagelayer", "name": "background"}]
        \\}
    });
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "unsupported.tmj" });
    defer std.testing.allocator.free(path);
    var diagnostic = Diagnostic{};
    try std.testing.expectError(error.UnsupportedTiledImageLayer, importFile(std.testing.allocator, path, &diagnostic));
    try std.testing.expectEqual(@as(usize, 6), diagnostic.line);
    try std.testing.expect(diagnostic.column > 0);
    try std.testing.expectEqualStrings("image layers are unsupported; use tile layers", diagnostic.message);
}

test "unsafe Tiled asset paths report their source location" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "unsafe.tmj", .data =
        \\{
        \\  "orientation": "orthogonal",
        \\  "tilewidth": 8,
        \\  "tileheight": 8,
        \\  "tilesets": [{
        \\    "firstgid": 1, "name": "tiles", "tilewidth": 8, "tileheight": 8, "image": "../../../../outside.png"
        \\  }],
        \\  "layers": []
        \\}
    });
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "unsafe.tmj" });
    defer std.testing.allocator.free(path);
    var diagnostic = Diagnostic{};
    try std.testing.expectError(error.UnsafeTiledAssetPath, importFile(std.testing.allocator, path, &diagnostic));
    try std.testing.expectEqual(@as(usize, 6), diagnostic.line);
    try std.testing.expect(diagnostic.column > 0);
    try std.testing.expectEqualStrings("asset path escapes the current directory; move it under the project", diagnostic.message);
}
