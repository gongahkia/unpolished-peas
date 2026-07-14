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

    var native_diagnostic = map_source.Diagnostic{};
    return native_map_export.encode(allocator, map, std.fs.path.stem(input_path), &native_diagnostic) catch |err| {
        if (err == error.UnsafeAssetPath) {
            setConversionDiagnostic(diagnostic, input, error.UnsafeTiledAssetPath);
            return error.UnsafeTiledAssetPath;
        }
        if (err == error.InvalidMapSource) {
            diagnostic.* = .{
                .line = native_diagnostic.line,
                .column = native_diagnostic.column,
                .message = native_diagnostic.message,
            };
            return error.InvalidTiledContent;
        }
        return err;
    };
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
