const std = @import("std");
const up = @import("unpolished-peas").api;
const bounce = @import("bounce.zig");
const platformer = @import("platformer_game.zig");
const topdown = @import("topdown_game.zig");

const golden_path = "headless-reference.png";
const bounce_golden_path = "proof-bounce-reference.png";
const topdown_golden_path = "proof-topdown-reference.png";
const platformer_golden_path = "proof-platformer-reference.png";
const diagnostics_path = "zig-out/scenes";
const expected_hash: u64 = 0xb110a7d1f1344c2e;
const bounce_expected_hash: u64 = 0x88b572d8695fbf0b;
const topdown_expected_hash: u64 = 0x72de84f88f57f5cb;
const platformer_expected_hash: u64 = 0x789ca28f71ab050c;

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

    var canvas = try renderScene(allocator, &assets);
    defer canvas.deinit();
    var bounce_canvas = try renderBounce(allocator);
    defer bounce_canvas.deinit();
    var topdown_canvas = try renderTopdown(allocator, &assets);
    defer topdown_canvas.deinit();
    var platformer_canvas = try renderPlatformer(allocator, &assets);
    defer platformer_canvas.deinit();

    if (update_golden) {
        try writeGolden(allocator, &assets, golden_path, canvas);
        try writeGolden(allocator, &assets, bounce_golden_path, bounce_canvas);
        try writeGolden(allocator, &assets, topdown_golden_path, topdown_canvas);
        return writeGolden(allocator, &assets, platformer_golden_path, platformer_canvas);
    }

    try assertGolden(allocator, &assets, golden_path, canvas, expected_hash, diagnostics_path);
    try assertGolden(allocator, &assets, bounce_golden_path, bounce_canvas, bounce_expected_hash, "zig-out/scenes/bounce");
    try assertGolden(allocator, &assets, topdown_golden_path, topdown_canvas, topdown_expected_hash, "zig-out/scenes/topdown");
    try assertGolden(allocator, &assets, platformer_golden_path, platformer_canvas, platformer_expected_hash, "zig-out/scenes/platformer");
}

fn renderScene(allocator: std.mem.Allocator, assets: *up.AssetStore) !up.Canvas {
    const ball = try assets.loadImage("ball.png");
    const atlas = try assets.loadAtlas("atlas.json");
    const map = try assets.loadTileMap("topdown.upmap", .{});
    const source_atlas = try assets.tryAtlas(atlas);
    var canvas = try up.Canvas.init(allocator, 64, 48);

    canvas.clear(up.Color.rgb(14, 18, 24));
    const tile_camera = up.Camera2D{ .position = .{ .x = 32, .y = 24 } };
    try assets.drawTileMap(map, &tile_camera, &canvas, 0);
    canvas.fillRect(4, 4, 12, 10, up.Color.rgb(255, 198, 74));
    canvas.drawImage(try assets.tryImage(ball), 24, 16);
    canvas.drawAtlasFrame(source_atlas, source_atlas.findFrame("tile_a").?, 48, 4, .{ .scale = 2, .tint = up.Color.rgb(255, 180, 120) });
    canvas.drawAtlasFrame(source_atlas, source_atlas.findFrame("tile_b").?, 58, 16, .{ .origin = .center, .scale = 2, .flip_x = true, .rotation = 0.25, .sampling = .linear });
    canvas.drawAtlasFrame(source_atlas, source_atlas.findFrame("tile_c").?, 52, 28, .{ .origin = .center, .scale = 2, .flip_y = true, .tint = up.Color.rgb(180, 255, 220), .rotation = -0.2 });
    canvas.drawText("TEST", 4, 36, up.Color.white);
    const camera = up.Camera2D{ .position = .{ .x = 32, .y = 24 }, .zoom = 1.5, .rotation = 0.15, .pixel_snap = .off };
    const world = up.CameraCanvas.init(&canvas, &camera);
    world.fillRect(.init(20, 10, 14, 8), up.Color.rgb(91, 166, 210));
    world.fillCircle(.{ .x = 44, .y = 30 }, 4, up.Color.rgb(255, 112, 112));
    const previous_clip = canvas.pushClip(.{ .x = 2, .y = 28, .w = 18, .h = 12 });
    canvas.fillRect(0, 26, 24, 16, up.Color.rgba(91, 166, 210, 180));
    const previous_blend = canvas.setBlend(.additive);
    canvas.fillCircle(10, 34, 8, up.Color.rgba(255, 112, 112, 160));
    _ = canvas.setBlend(previous_blend);
    canvas.restoreClip(previous_clip);

    return canvas;
}

fn renderBounce(allocator: std.mem.Allocator) !up.Canvas {
    var canvas = try up.Canvas.init(allocator, bounce.width, bounce.height);
    var clock = up.StepClock.init(60);
    var ball = bounce.Ball{};

    var frame: u32 = 0;
    while (frame < 180) : (frame += 1) {
        const steps = clock.push(1.0 / 60.0);
        var step: u32 = 0;
        while (step < steps) : (step += 1) ball.update(clock.step_seconds, @floatFromInt(canvas.width), @floatFromInt(canvas.height));

        canvas.clear(up.Color.rgb(14, 18, 24));
        var x: i32 = 0;
        while (x < @as(i32, @intCast(canvas.width))) : (x += 16) canvas.line(x, 0, x, @intCast(canvas.height - 1), up.Color.rgb(32, 39, 50));
        var y: i32 = 0;
        while (y < @as(i32, @intCast(canvas.height))) : (y += 16) canvas.line(0, y, @intCast(canvas.width - 1), y, up.Color.rgb(32, 39, 50));
        canvas.strokeRect(0, 0, @intCast(canvas.width), @intCast(canvas.height), up.Color.rgb(91, 104, 124));
        canvas.fillCircle(@intFromFloat(ball.pos.x), @intFromFloat(ball.pos.y), ball.radius, up.Color.rgb(255, 198, 74));
        canvas.drawText("UNPOLISHED", 4, 4, up.Color.rgb(225, 232, 240));
    }
    return canvas;
}

fn renderTopdown(allocator: std.mem.Allocator, assets: *up.AssetStore) !up.Canvas {
    const map = try assets.loadTileMap("topdown.upmap", .{});
    const player = try assets.loadImage("ball.png");
    var game = topdown.Game{};
    var input = up.Input{};
    input.set(.right, true);
    input.set(.down, true);
    var frame: u32 = 0;
    while (frame < 60) : (frame += 1) _ = game.step(input, 1.0 / 60.0);

    var canvas = try up.Canvas.init(allocator, topdown.width, topdown.height);
    canvas.clear(up.Color.rgb(10, 18, 26));
    const camera = up.Camera2D{ .position = game.player };
    try assets.drawTileMap(map, &camera, &canvas, 0);
    canvas.drawImage(try assets.tryImage(player), @intFromFloat(game.player.x - 8), @intFromFloat(game.player.y - 8));
    canvas.drawText("TOPDOWN", 4, 4, up.Color.white);
    canvas.drawText("ARROWS SPACE", 84, 4, up.Color.rgb(180, 205, 230));
    return canvas;
}

fn renderPlatformer(allocator: std.mem.Allocator, assets: *up.AssetStore) !up.Canvas {
    const map = try assets.loadTileMap("platformer.upmap", .{});
    var collider = up.TileCollider.init(allocator);
    defer collider.deinit();
    try collider.addLayer(try assets.tryTileMapPtr(map), 0);
    const atlas = try assets.loadAtlas("atlas.json");
    const source_atlas = try assets.tryAtlasPtr(atlas);
    const animation_handle = source_atlas.findAnimation("pulse") orelse return error.MissingAtlasAnimation;
    var animation = up.AnimationPlayer.init(source_atlas, animation_handle);
    var game = try platformer.Game.init(.{ .x = 8, .y = 0 });
    var frame: u32 = 0;
    while (frame < 96) : (frame += 1) {
        _ = game.step(&collider, .{ .right = frame < 48, .jump = frame == 48 }, 1.0 / 60.0);
        animation.update(1.0 / 60.0);
    }

    var canvas = try up.Canvas.init(allocator, 160, 64);
    canvas.clear(up.Color.rgb(12, 18, 28));
    const camera = up.Camera2D{ .position = .{ .x = 48, .y = 24 } };
    try assets.drawTileMap(map, &camera, &canvas, 0);
    canvas.drawAtlasFrame(source_atlas.*, animation.frame(), @intFromFloat(game.controller.bounds.x), @intFromFloat(game.controller.bounds.y), .{ .scale = 2 });
    canvas.fillCircle(84, 8, 2, up.Color.rgb(255, 198, 74));
    canvas.drawText("PLATFORMER", 2, 2, up.Color.white);
    return canvas;
}

fn writeGolden(allocator: std.mem.Allocator, assets: *up.AssetStore, path: []const u8, canvas: up.Canvas) !void {
    const output_path = try assets.assetPath(allocator, path);
    defer allocator.free(output_path);
    try canvas.writePngFile(output_path);
}

fn assertGolden(allocator: std.mem.Allocator, assets: *up.AssetStore, path: []const u8, canvas: up.Canvas, hash: u64, diagnostics: []const u8) !void {
    const golden = try assets.loadImage(path);
    try up.testSupport.assertGolden(allocator, canvas, try assets.tryImage(golden), .{ .expected_hash = hash, .diagnostics_path = diagnostics });
}
