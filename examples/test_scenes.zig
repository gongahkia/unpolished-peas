const std = @import("std");
const up = @import("unpolished-peas").api;

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
    try up.testSupport.assertGolden(allocator, canvas, assets.image(golden), .{ .expected_hash = expected_hash, .diagnostics_path = diagnostics_path });
}
