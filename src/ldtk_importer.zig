const std = @import("std");
const Camera2D = @import("camera.zig").Camera2D;
const CameraCanvas = @import("camera_canvas.zig").CameraCanvas;
const Canvas = @import("canvas.zig").Canvas;
const Color = @import("color.zig").Color;
const Image = @import("image.zig").Image;
const map_source = @import("map_source.zig");
const native_map_export = @import("native_map_export.zig");
const tilemap = @import("tilemap.zig");

const max_source_bytes = 64 * 1024 * 1024;
const Location = struct { line: usize, column: usize };

pub const Diagnostic = struct {
    line: usize = 1,
    column: usize = 1,
    message: []const u8 = "invalid LDtk project",
};

pub const Map = struct {
    name: []u8,
    source: []u8,

    pub fn deinit(self: *Map, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.source);
        self.* = undefined;
    }
};

pub const Result = struct {
    maps: []Map,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        for (self.maps) |*map| map.deinit(allocator);
        allocator.free(self.maps);
        self.* = undefined;
    }
};

pub fn importFile(allocator: std.mem.Allocator, input_path: []const u8, diagnostic: *Diagnostic) !Result {
    const input = std.fs.cwd().readFileAlloc(allocator, input_path, max_source_bytes) catch |err| {
        diagnostic.* = .{ .message = "unable to read LDtk source" };
        return err;
    };
    defer allocator.free(input);
    var project = tilemap.TileMap.loadLdtkProject(allocator, input_path) catch |err| {
        setLoadDiagnostic(diagnostic, input, err);
        return err;
    };
    defer project.deinit();

    const maps = try allocator.alloc(Map, project.levels.items.len);
    var initialized: usize = 0;
    errdefer {
        for (maps[0..initialized]) |*map| map.deinit(allocator);
        allocator.free(maps);
    }
    for (project.levels.items) |level| {
        if (!safeName(level.identifier)) {
            setConversionDiagnostic(diagnostic, input, error.UnsafeLevelIdentifier);
            return error.UnsafeLevelIdentifier;
        }
        for (maps[0..initialized]) |existing| if (std.mem.eql(u8, existing.name, level.identifier)) {
            setConversionDiagnostic(diagnostic, input, error.DuplicateLevelIdentifier);
            return error.DuplicateLevelIdentifier;
        };
        var native_diagnostic = map_source.Diagnostic{};
        const source = native_map_export.encode(allocator, level.map, level.identifier, &native_diagnostic) catch |err| {
            if (err == error.UnsafeAssetPath) {
                setConversionDiagnostic(diagnostic, input, error.UnsafeLdtkAssetPath);
                return error.UnsafeLdtkAssetPath;
            }
            if (err == error.InvalidMapSource) {
                diagnostic.* = .{
                    .line = native_diagnostic.line,
                    .column = native_diagnostic.column,
                    .message = native_diagnostic.message,
                };
                return error.InvalidLdtkContent;
            }
            return err;
        };
        errdefer allocator.free(source);
        maps[initialized] = .{
            .name = try allocator.dupe(u8, level.identifier),
            .source = source,
        };
        initialized += 1;
    }
    return .{ .maps = maps };
}

fn safeName(value: []const u8) bool {
    if (value.len == 0 or std.fs.path.isAbsolute(value)) return false;
    for (value) |byte| if (byte == '/' or byte == '\\') return false;
    return !std.mem.eql(u8, value, ".") and !std.mem.eql(u8, value, "..");
}

fn setLoadDiagnostic(diagnostic: *Diagnostic, source: []const u8, err: anyerror) void {
    const detail = switch (err) {
        error.UnsupportedLdtkFeature => .{ "\"__type\"", "unsupported LDtk layer; use IntGrid, Tiles, AutoLayer, or Entities" },
        error.UnsupportedLdtkField => .{ "\"__type\"", "unsupported LDtk field; use Int, Float, Bool, String, Text, or FilePath" },
        else => .{ "", "invalid LDtk project; validate it in LDtk" },
    };
    const location = if (err == error.UnsupportedLdtkField) lastLocationOf(source, detail[0]) else locationOf(source, detail[0]);
    diagnostic.* = .{ .line = location.line, .column = location.column, .message = detail[1] };
}

fn setConversionDiagnostic(diagnostic: *Diagnostic, source: []const u8, err: anyerror) void {
    const detail: struct { []const u8, []const u8 } = switch (err) {
        error.UnsafeLdtkAssetPath => .{ "\"relPath\"", "asset path escapes the current directory; move it under the project" },
        error.UnsafeLevelIdentifier => .{ "\"identifier\"", "level identifiers must be nonempty file names" },
        error.DuplicateLevelIdentifier => .{ "\"identifier\"", "level identifiers must be unique" },
        else => .{ "", "LDtk project cannot be converted to native source" },
    };
    const location = locationOf(source, detail[0]);
    diagnostic.* = .{ .line = location.line, .column = location.column, .message = detail[1] };
}

fn locationOf(source: []const u8, needle: []const u8) Location {
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

fn lastLocationOf(source: []const u8, needle: []const u8) Location {
    const offset = std.mem.lastIndexOf(u8, source, needle) orelse return .{ .line = 1, .column = 1 };
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

test "imports external LDtk levels with supported fields and equivalent rendering" {
    var diagnostic = Diagnostic{};
    var imported = try importFile(std.testing.allocator, "fixtures/ldtk/v1/project.ldtk", &diagnostic);
    defer imported.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), imported.maps.len);
    try std.testing.expectEqualStrings("Main", imported.maps[0].name);
    try std.testing.expectEqualStrings("External", imported.maps[1].name);

    var source_diagnostic = map_source.Diagnostic{};
    var source = try map_source.parse(std.testing.allocator, imported.maps[0].source, &source_diagnostic);
    defer source.deinit(std.testing.allocator);
    var native = try source.build(std.testing.allocator);
    defer native.deinit();
    var project = try tilemap.TileMap.loadLdtkProject(std.testing.allocator, "fixtures/ldtk/v1/project.ldtk");
    defer project.deinit();
    const ldtk = &project.levels.items[0].map;
    try std.testing.expectEqual(ldtk.tileAt(0, .{ .x = 0, .y = 0 }).?.flags.flip_x, native.tileAt(0, .{ .x = 0, .y = 0 }).?.flags.flip_x);
    try std.testing.expectEqual(@as(i32, 1), native.intGridAt(1, .{ .x = 1, .y = 0 }).?);
    try std.testing.expectEqual(@as(usize, 2), native.layerObjects(2).len);
    try std.testing.expect(native.layerObjects(2)[0].id != native.layerObjects(2)[1].id);

    var pixels: [64]Color = undefined;
    for (&pixels, 0..) |*pixel, index| pixel.* = if (index % 8 == 0) Color.rgb(255, 0, 0) else Color.rgb(0, 255, 0);
    const image = Image{ .allocator = std.testing.allocator, .width = 8, .height = 8, .pixels = &pixels };
    var ldtk_canvas = try Canvas.init(std.testing.allocator, 16, 16);
    defer ldtk_canvas.deinit();
    var native_canvas = try Canvas.init(std.testing.allocator, 16, 16);
    defer native_canvas.deinit();
    ldtk_canvas.clear(Color.black);
    native_canvas.clear(Color.black);
    const camera = Camera2D{ .position = .{ .x = 8, .y = 8 } };
    ldtk.drawImages(CameraCanvas.init(&ldtk_canvas, &camera), &.{image});
    native.drawImages(CameraCanvas.init(&native_canvas, &camera), &.{image});
    try std.testing.expectEqualSlices(Color, ldtk_canvas.pixels, native_canvas.pixels);

    var external_source_diagnostic = map_source.Diagnostic{};
    var external_source = try map_source.parse(std.testing.allocator, imported.maps[1].source, &external_source_diagnostic);
    defer external_source.deinit(std.testing.allocator);
    var external = try external_source.build(std.testing.allocator);
    defer external.deinit();
    try std.testing.expectEqual(@as(i32, 7), external.intGridAt(0, .{ .x = 0, .y = 0 }).?);
}

test "unsupported LDtk layers report their source location" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source =
        \\{
        \\  "defs": {"tilesets": []},
        \\  "levels": [{
        \\    "identifier": "Main",
        \\    "layerInstances": [{
        \\      "__type": "IntGridAutoLayer",
        \\      "__identifier": "Unsupported",
        \\      "visible": true,
        \\      "__opacity": 1,
        \\      "__gridSize": 8,
        \\      "__cWid": 1,
        \\      "intGridCsv": [0]
        \\    }]
        \\  }]
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "unsupported.ldtk", .data = source });
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "unsupported.ldtk" });
    defer std.testing.allocator.free(path);
    var diagnostic = Diagnostic{};
    try std.testing.expectError(error.UnsupportedLdtkFeature, importFile(std.testing.allocator, path, &diagnostic));
    try std.testing.expectEqual(@as(usize, 6), diagnostic.line);
    try std.testing.expect(diagnostic.column > 0);
    try std.testing.expectEqualStrings("unsupported LDtk layer; use IntGrid, Tiles, AutoLayer, or Entities", diagnostic.message);
}

test "unsupported LDtk fields report their source location" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source =
        \\{
        \\  "defs": {"tilesets": []},
        \\  "levels": [{
        \\    "identifier": "Main",
        \\    "layerInstances": [{
        \\      "__type": "Entities",
        \\      "__identifier": "Entities",
        \\      "visible": true,
        \\      "__opacity": 1,
        \\      "__gridSize": 8,
        \\      "entityInstances": [{
        \\        "defUid": 7, "__identifier": "Wall", "px": [0, 0], "width": 8, "height": 8,
        \\        "fieldInstances": [{"__identifier": "tint", "__type": "Color", "__value": "#fff"}]
        \\      }]
        \\    }]
        \\  }]
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "unsupported-field.ldtk", .data = source });
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "unsupported-field.ldtk" });
    defer std.testing.allocator.free(path);
    var diagnostic = Diagnostic{};
    try std.testing.expectError(error.UnsupportedLdtkField, importFile(std.testing.allocator, path, &diagnostic));
    try std.testing.expectEqual(@as(usize, 13), diagnostic.line);
    try std.testing.expect(diagnostic.column > 0);
    try std.testing.expectEqualStrings("unsupported LDtk field; use Int, Float, Bool, String, Text, or FilePath", diagnostic.message);
}
