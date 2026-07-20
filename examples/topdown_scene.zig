const std = @import("std");
const up = @import("unpolished-peas");
const game_mod = @import("topdown_game.zig");

const golden_path = "proof-topdown-reference.png";
const expected_hash: u64 = 0xefd8742b76f65f2d;
const diagnostics_path = "zig-out/scenes/topdown";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    var update_golden = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--update-golden")) update_golden = true;
    }
    var assets = try up.assets.AssetStore.initExecutable(allocator);
    defer assets.deinit();
    const player = try assets.loadImage("ball.png");
    var canvas = try renderTopDown(allocator, try assets.tryImage(player));
    defer canvas.deinit();
    if (update_golden) return writeGolden(allocator, &assets, golden_path, canvas);
    try assertGolden(allocator, &assets, golden_path, canvas, expected_hash, diagnostics_path);
}

fn renderTopDown(allocator: std.mem.Allocator, player: up.assets.Image) !up.graphics.Canvas {
    var game = game_mod.Game{};
    var input = up.input.Input{};
    input.set(.right, true);
    input.set(.down, true);
    var frame: u32 = 0;
    while (frame < 34) : (frame += 1) _ = game.step(input, 1.0 / 60.0);
    input.set(.action, true);
    _ = game.step(input, 1.0 / 60.0);
    var canvas = try up.graphics.Canvas.init(allocator, game_mod.width, game_mod.height);
    canvas.clear(up.core.Color.rgb(10, 18, 26));
    const camera = up.graphics.Camera2D{ .position = game.player, .zoom = 1.25 };
    const world = up.graphics.CameraCanvas.init(&canvas, &camera);
    drawWorld(world);
    world.line(game.player, game.player.add(game.aim.scale(12)), up.core.Color.rgb(255, 198, 74));
    world.drawImage(player, game.player.sub(.{ .x = 8, .y = 8 }));
    canvas.drawText("TOPDOWN", 4, 4, up.core.Color.white);
    canvas.drawText("CAMERA 1.25X", 75, 4, up.core.Color.rgb(180, 205, 230));
    return canvas;
}

fn drawWorld(world: up.graphics.CameraCanvas) void {
    var x: i32 = 0;
    while (x <= game_mod.width) : (x += 16) world.line(.{ .x = @floatFromInt(x), .y = 0 }, .{ .x = @floatFromInt(x), .y = game_mod.height }, up.core.Color.rgb(23, 35, 47));
    var y: i32 = 0;
    while (y <= game_mod.height) : (y += 16) world.line(.{ .x = 0, .y = @floatFromInt(y) }, .{ .x = game_mod.width, .y = @floatFromInt(y) }, up.core.Color.rgb(23, 35, 47));
    world.strokeRect(.init(8, 18, 144, 70), up.core.Color.rgb(91, 166, 210));
    world.fillRect(.init(24, 31, 24, 12), up.core.Color.rgb(51, 96, 122));
    world.fillRect(.init(108, 56, 20, 16), up.core.Color.rgb(133, 66, 61));
    world.fillCircle(.{ .x = 32, .y = 42 }, 4, up.core.Color.rgb(255, 198, 74));
    world.fillCircle(.{ .x = 128, .y = 62 }, 4, up.core.Color.rgb(113, 232, 162));
}

fn writeGolden(allocator: std.mem.Allocator, assets: *up.assets.AssetStore, path: []const u8, canvas: up.graphics.Canvas) !void {
    const output_path = try assets.assetPath(allocator, path);
    defer allocator.free(output_path);
    try canvas.writePngFile(output_path);
}

fn assertGolden(allocator: std.mem.Allocator, assets: *up.assets.AssetStore, path: []const u8, canvas: up.graphics.Canvas, hash: u64, diagnostics: []const u8) !void {
    const golden = try assets.loadImage(path);
    try up.testSupport.assertGolden(allocator, canvas, try assets.tryImage(golden), .{ .expected_hash = hash, .diagnostics_path = diagnostics });
}
