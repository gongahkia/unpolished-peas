const std = @import("std");
const up = @import("unpolished-peas");

const golden_path = "headless-reference.png";
const diagnostics_path = "zig-out/scenes";
const expected_hash: u64 = 0x2a1440decbfca661;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    var update_golden = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--update-golden")) update_golden = true;
    }

    var assets = try up.AssetStore.initExecutable(allocator);
    defer assets.deinit();
    const ball = try assets.loadPng("ball.png");
    const atlas = try assets.loadAtlas("atlas.json");
    const source_atlas = assets.atlas(atlas);

    var canvas = try up.Canvas.init(allocator, 64, 48);
    defer canvas.deinit();

    canvas.clear(up.Color.rgb(14, 18, 24));
    canvas.fillRect(4, 4, 12, 10, up.Color.rgb(255, 198, 74));
    canvas.drawImage(assets.image(ball), 24, 16);
    canvas.drawAtlasFrame(source_atlas, source_atlas.findFrame("tile_a").?, 48, 4, .{ .scale = 2, .tint = up.Color.rgb(255, 180, 120) });
    canvas.drawAtlasFrame(source_atlas, source_atlas.findFrame("tile_b").?, 58, 16, .{ .origin = .center, .scale = 2, .flip_x = true, .rotation = 0.25, .sampling = .linear });
    canvas.drawAtlasFrame(source_atlas, source_atlas.findFrame("tile_c").?, 52, 28, .{ .origin = .center, .scale = 2, .flip_y = true, .tint = up.Color.rgb(180, 255, 220), .rotation = -0.2 });
    canvas.drawText("TEST", 4, 36, up.Color.white);
    const camera = up.Camera2D{ .position = .{ .x = 32, .y = 24 }, .zoom = 1.5, .rotation = 0.15, .pixel_snap = .off };
    const world = up.CameraCanvas.init(&canvas, &camera);
    world.fillRect(.init(20, 10, 14, 8), up.Color.rgb(91, 166, 210));
    world.fillCircle(.{ .x = 44, .y = 30 }, 4, up.Color.rgb(255, 112, 112));

    if (update_golden) {
        const path = try assets.assetPath(allocator, golden_path);
        defer allocator.free(path);
        return canvas.writePngFile(path);
    }

    const golden = try assets.loadPng(golden_path);
    try assertGolden(allocator, canvas, assets.image(golden));
}

fn assertGolden(allocator: std.mem.Allocator, actual: up.Canvas, expected: up.Image) !void {
    if (hashCanvas(actual) == expected_hash and actual.width == expected.width and actual.height == expected.height and pixelsEqual(actual.pixels, expected.pixels)) return;

    try writeDiagnostics(allocator, actual, expected);
    return error.SceneGoldenMismatch;
}

fn writeDiagnostics(allocator: std.mem.Allocator, actual: up.Canvas, expected: up.Image) !void {
    try std.fs.cwd().makePath(diagnostics_path);
    try actual.writePngFile(diagnostics_path ++ "/actual.png");

    var expected_canvas = try up.Canvas.init(allocator, expected.width, expected.height);
    defer expected_canvas.deinit();
    @memcpy(expected_canvas.pixels, expected.pixels);
    try expected_canvas.writePngFile(diagnostics_path ++ "/expected.png");

    var diff = try up.Canvas.init(allocator, @max(actual.width, expected.width), @max(actual.height, expected.height));
    defer diff.deinit();
    for (diff.pixels, 0..) |*pixel, index| {
        const x = index % diff.width;
        const y = index / diff.width;
        const actual_pixel = if (x < actual.width and y < actual.height) actual.pixels[y * actual.width + x] else up.Color.transparent;
        const expected_pixel = if (x < expected.width and y < expected.height) expected.pixels[y * expected.width + x] else up.Color.transparent;
        pixel.* = if (std.meta.eql(actual_pixel, expected_pixel)) up.Color.transparent else up.Color.rgba(255, 0, 255, 255);
    }
    try diff.writePngFile(diagnostics_path ++ "/diff.png");
}

fn pixelsEqual(actual: []const up.Color, expected: []const up.Color) bool {
    if (actual.len != expected.len) return false;
    for (actual, expected) |a, b| if (!std.meta.eql(a, b)) return false;
    return true;
}

fn hashCanvas(canvas: up.Canvas) u64 {
    var hasher = std.hash.Fnv1a_64.init();
    for (canvas.pixels) |pixel| hasher.update(&.{ pixel.r, pixel.g, pixel.b, pixel.a });
    return hasher.final();
}
