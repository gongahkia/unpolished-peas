const std = @import("std");

pub const native_format = "unpolished-peas-map";
pub const native_version: u32 = 1;

pub const Projection = enum { orthogonal, isometric };
pub const LayerKind = enum { tiles, int_grid, group, objects };
pub const TileSourceKind = enum { grid_image, image_collection, atlas_frames };
pub const Shape = enum { rectangle, ellipse, point, polygon, polyline };

pub const Metadata = struct {
    name: []const u8,
    projection: Projection,
    tile_width: f32,
    tile_height: f32,
    chunk_size: u32,
};

pub const TileSet = struct {
    id: []const u8,
    kind: TileSourceKind,
    path: []const u8,
    tile_width: f32,
    tile_height: f32,
    margin: u32 = 0,
    spacing: u32 = 0,
    atlas_frames: []const []const u8 = &.{},
};

pub const Tile = struct {
    tileset: []const u8,
    id: u32,
    flip_x: bool = false,
    flip_y: bool = false,
    diagonal: bool = false,
    opacity: f32 = 1,
};

pub const Cell = struct {
    x: i32,
    y: i32,
    tiles: []const Tile = &.{},
    int_grid: ?i32 = null,
};

pub const Point = struct {
    x: f32,
    y: f32,
};

pub const Property = struct {
    name: []const u8,
    string: ?[]const u8 = null,
    integer: ?i64 = null,
    float: ?f64 = null,
    boolean: ?bool = null,
};

pub const Object = struct {
    id: []const u8,
    name: []const u8,
    class_name: []const u8 = "",
    x: f32,
    y: f32,
    width: f32 = 0,
    height: f32 = 0,
    shape: Shape = .rectangle,
    points: []const Point = &.{},
    properties: []const Property = &.{},
};

pub const Layer = struct {
    id: []const u8,
    name: []const u8,
    kind: LayerKind,
    parent: ?[]const u8 = null,
    visible: bool = true,
    opacity: f32 = 1,
    offset_x: f32 = 0,
    offset_y: f32 = 0,
    parallax_x: f32 = 1,
    parallax_y: f32 = 1,
    cells: []const Cell = &.{},
    objects: []const Object = &.{},
    properties: []const Property = &.{},
};

pub const Source = struct {
    format: []const u8,
    version: u32,
    metadata: Metadata,
    tilesets: []const TileSet,
    layers: []const Layer,

    pub fn deinit(self: *Source, allocator: std.mem.Allocator) void {
        std.zon.parse.free(allocator, self.*);
        self.* = undefined;
    }

    pub fn encode(self: Source, allocator: std.mem.Allocator) ![]u8 {
        var output = std.Io.Writer.Allocating.init(allocator);
        defer output.deinit();
        try std.zon.stringify.serialize(self, .{}, &output.writer);
        return allocator.dupe(u8, output.written());
    }
};

pub const Diagnostic = struct {
    line: usize = 1,
    column: usize = 1,
    message: []const u8 = "invalid map",
};

pub fn parse(allocator: std.mem.Allocator, source: []const u8, diagnostic: *Diagnostic) !Source {
    var zon_diagnostics: std.zon.parse.Diagnostics = .{};
    defer zon_diagnostics.deinit(allocator);
    var parsed = std.zon.parse.fromSlice(Source, allocator, source, &zon_diagnostics, .{ .ignore_unknown_fields = false }) catch |err| switch (err) {
        error.ParseZon => {
            var errors = zon_diagnostics.iterateErrors();
            if (errors.next()) |parse_error| {
                const location = parse_error.getLocation(&zon_diagnostics);
                diagnostic.* = .{ .line = location.line + 1, .column = location.column + 1 };
            }
            return err;
        },
        else => return err,
    };
    errdefer parsed.deinit(allocator);
    try validate(parsed, source, diagnostic);
    return parsed;
}

pub fn load(allocator: std.mem.Allocator, source: []const u8) !Source {
    var diagnostic = Diagnostic{};
    return parse(allocator, source, &diagnostic);
}

fn validate(map: Source, source: []const u8, diagnostic: *Diagnostic) !void {
    if (!std.mem.eql(u8, map.format, native_format)) return fail(diagnostic, source, "format", "unsupported map format");
    if (map.version != native_version) return fail(diagnostic, source, "version", "unsupported map version");
    if (map.metadata.name.len == 0) return fail(diagnostic, source, "metadata", "map metadata requires a name");
    if (!positiveFinite(map.metadata.tile_width) or !positiveFinite(map.metadata.tile_height) or !validChunkSize(map.metadata.chunk_size)) return fail(diagnostic, source, "metadata", "map tile dimensions and chunk size are invalid");
    try validateTileSets(map, source, diagnostic);
    try validateLayers(map, source, diagnostic);
}

fn validateTileSets(map: Source, source: []const u8, diagnostic: *Diagnostic) !void {
    for (map.tilesets, 0..) |tileset, index| {
        if (tileset.id.len == 0 or !safePath(tileset.path) or !positiveFinite(tileset.tile_width) or !positiveFinite(tileset.tile_height)) return fail(diagnostic, source, "tilesets", "tilesets require a unique id, safe path, and positive tile dimensions");
        for (map.tilesets[0..index]) |previous| if (std.mem.eql(u8, previous.id, tileset.id)) return fail(diagnostic, source, "tilesets", "tileset ids must be unique");
        for (tileset.atlas_frames, 0..) |frame, frame_index| {
            if (frame.len == 0 or (frame_index != 0 and std.mem.order(u8, tileset.atlas_frames[frame_index - 1], frame) != .lt)) return fail(diagnostic, source, "atlas_frames", "atlas frame names must be nonempty, unique, and sorted");
        }
    }
}

fn validateLayers(map: Source, source: []const u8, diagnostic: *Diagnostic) !void {
    for (map.layers, 0..) |layer, index| {
        if (layer.id.len == 0 or layer.name.len == 0) return fail(diagnostic, source, "layers", "layers require nonempty id and name");
        for (map.layers[0..index]) |previous| if (std.mem.eql(u8, previous.id, layer.id)) return fail(diagnostic, source, "layers", "layer ids must be unique");
        if (!unitFinite(layer.opacity) or !finite(layer.offset_x) or !finite(layer.offset_y) or !finite(layer.parallax_x) or !finite(layer.parallax_y)) return fail(diagnostic, source, "layers", "layer transform and opacity values are invalid");
        if (layer.parent) |parent| {
            const parent_layer = findPriorLayer(map.layers, index, parent) orelse return fail(diagnostic, source, "parent", "layer parent must reference an earlier group layer");
            if (parent_layer.kind != .group) return fail(diagnostic, source, "parent", "layer parent must reference a group layer");
        }
        try validateProperties(layer.properties, source, diagnostic);
        switch (layer.kind) {
            .tiles => {
                if (layer.objects.len != 0) return fail(diagnostic, source, "objects", "tile layers cannot contain objects");
                try validateCells(map, layer.cells, .tiles, source, diagnostic);
            },
            .int_grid => {
                if (layer.objects.len != 0) return fail(diagnostic, source, "objects", "int-grid layers cannot contain objects");
                try validateCells(map, layer.cells, .int_grid, source, diagnostic);
            },
            .group => if (layer.cells.len != 0 or layer.objects.len != 0) return fail(diagnostic, source, "layers", "group layers cannot contain cells or objects"),
            .objects => {
                if (layer.cells.len != 0) return fail(diagnostic, source, "cells", "object layers cannot contain cells");
                try validateObjects(layer.objects, source, diagnostic);
            },
        }
    }
}

fn validateCells(map: Source, cells: []const Cell, kind: LayerKind, source: []const u8, diagnostic: *Diagnostic) !void {
    for (cells, 0..) |cell, index| {
        if (index != 0 and cellOrder(cells[index - 1], cell) != .lt) return fail(diagnostic, source, "cells", "cell coordinates must be unique and sorted");
        switch (kind) {
            .tiles => {
                if (cell.tiles.len == 0 or cell.int_grid != null) return fail(diagnostic, source, "cells", "tile cells require tiles and cannot contain int-grid values");
                for (cell.tiles) |tile| {
                    if (!hasTileSet(map.tilesets, tile.tileset) or !unitFinite(tile.opacity)) return fail(diagnostic, source, ".tileset =", "tile references an unknown tileset or has invalid opacity");
                }
            },
            .int_grid => if (cell.tiles.len != 0 or cell.int_grid == null) return fail(diagnostic, source, "cells", "int-grid cells require a value and cannot contain tiles"),
            else => unreachable,
        }
    }
}

fn validateObjects(objects: []const Object, source: []const u8, diagnostic: *Diagnostic) !void {
    for (objects, 0..) |object, index| {
        if (object.id.len == 0 or object.name.len == 0 or !finite(object.x) or !finite(object.y) or !finite(object.width) or !finite(object.height) or object.width < 0 or object.height < 0) return fail(diagnostic, source, "objects", "objects require ids, names, and finite nonnegative bounds");
        for (objects[0..index]) |previous| if (std.mem.eql(u8, previous.id, object.id)) return fail(diagnostic, source, "objects", "object ids must be unique within a layer");
        switch (object.shape) {
            .rectangle, .ellipse, .point => if (object.points.len != 0) return fail(diagnostic, source, "points", "rectangle, ellipse, and point objects cannot contain points"),
            .polygon => if (object.points.len < 3) return fail(diagnostic, source, "points", "polygon objects require at least three points"),
            .polyline => if (object.points.len < 2) return fail(diagnostic, source, "points", "polyline objects require at least two points"),
        }
        for (object.points) |point| if (!finite(point.x) or !finite(point.y)) return fail(diagnostic, source, "points", "object points must be finite");
        try validateProperties(object.properties, source, diagnostic);
    }
}

fn validateProperties(properties: []const Property, source: []const u8, diagnostic: *Diagnostic) !void {
    for (properties, 0..) |property, index| {
        if (property.name.len == 0 or propertyValueCount(property) != 1) return fail(diagnostic, source, "properties", "properties require a name and exactly one value");
        for (properties[0..index]) |previous| if (std.mem.eql(u8, previous.name, property.name)) return fail(diagnostic, source, "properties", "property names must be unique");
    }
}

fn propertyValueCount(property: Property) u3 {
    var count: u3 = 0;
    if (property.string != null) count += 1;
    if (property.integer != null) count += 1;
    if (property.float != null) count += 1;
    if (property.boolean != null) count += 1;
    return count;
}

fn findPriorLayer(layers: []const Layer, end: usize, id: []const u8) ?Layer {
    for (layers[0..end]) |layer| if (std.mem.eql(u8, layer.id, id)) return layer;
    return null;
}

fn hasTileSet(tilesets: []const TileSet, id: []const u8) bool {
    for (tilesets) |tileset| if (std.mem.eql(u8, tileset.id, id)) return true;
    return false;
}

fn cellOrder(left: Cell, right: Cell) std.math.Order {
    return if (left.y != right.y) std.math.order(left.y, right.y) else std.math.order(left.x, right.x);
}

fn validChunkSize(value: u32) bool {
    return value >= 8 and value <= 128 and std.math.isPowerOfTwo(value);
}

fn positiveFinite(value: f32) bool {
    return finite(value) and value > 0;
}

fn unitFinite(value: f32) bool {
    return finite(value) and value >= 0 and value <= 1;
}

fn finite(value: f32) bool {
    return std.math.isFinite(value);
}

fn safePath(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return false;
    var components = std.mem.tokenizeAny(u8, path, "/\\");
    while (components.next()) |component| if (std.mem.eql(u8, component, "..")) return false;
    return true;
}

fn fail(diagnostic: *Diagnostic, source: []const u8, field: []const u8, message: []const u8) error{InvalidMapSource} {
    const location = fieldLocation(source, field);
    diagnostic.* = .{ .line = location.line, .column = location.column, .message = message };
    return error.InvalidMapSource;
}

fn fieldLocation(source: []const u8, field: []const u8) struct { line: usize, column: usize } {
    const offset = std.mem.indexOf(u8, source, field) orelse return .{ .line = 1, .column = 1 };
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

test "native map source parses layers objects properties and signed cells" {
    const fixture = try std.fs.cwd().readFileAlloc(std.testing.allocator, "fixtures/maps/main.upmap", 64 * 1024);
    defer std.testing.allocator.free(fixture);
    var diagnostic = Diagnostic{};
    var map = try parse(std.testing.allocator, fixture, &diagnostic);
    defer map.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i32, -2), map.layers[1].cells[0].x);
    try std.testing.expectEqualStrings("tiles", map.layers[1].cells[0].tiles[0].tileset);
    try std.testing.expect(map.layers[3].objects[0].properties[0].boolean.?);
    const encoded = try map.encode(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    var decoded = try parse(std.testing.allocator, encoded, &diagnostic);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expect(std.meta.eql(map, decoded));
}

test "native map source reports precise validation errors" {
    const fixture = try std.fs.cwd().readFileAlloc(std.testing.allocator, "fixtures/maps/invalid-tileset.upmap", 64 * 1024);
    defer std.testing.allocator.free(fixture);
    var diagnostic = Diagnostic{};
    try std.testing.expectError(error.InvalidMapSource, parse(std.testing.allocator, fixture, &diagnostic));
    try std.testing.expectEqual(@as(usize, 10), diagnostic.line);
    try std.testing.expect(diagnostic.column > 0);
    try std.testing.expectEqualStrings("tile references an unknown tileset or has invalid opacity", diagnostic.message);
}
