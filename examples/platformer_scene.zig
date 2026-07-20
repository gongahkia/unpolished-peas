const std = @import("std");
const up = @import("unpolished-peas");
const game_mod = @import("platformer_game.zig");

const golden_path = "proof-platformer-reference.png";
const expected_hash: u64 = 0x5b5ef7b5bde7a911;
const diagnostics_path = "zig-out/scenes/platformer";

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
    var canvas = try renderPlatformer(allocator, try assets.tryImage(player));
    defer canvas.deinit();
    if (update_golden) return writeGolden(allocator, &assets, golden_path, canvas);
    try assertGolden(allocator, &assets, golden_path, canvas, expected_hash, diagnostics_path);
}

fn renderPlatformer(allocator: std.mem.Allocator, player: up.assets.Image) !up.graphics.Canvas {
    var game = game_mod.Game{};
    var input = up.input.Input{};
    input.set(.right, true);
    var frame: u32 = 0;
    while (frame < 45) : (frame += 1) {
        if (frame == 12) input.set(.action, true);
        if (frame == 13) input.set(.action, false);
        _ = game.step(input, 1.0 / 60.0);
    }
    var canvas = try up.graphics.Canvas.init(allocator, game_mod.width, game_mod.height);
    canvas.clear(up.core.Color.rgb(15, 23, 38));
    drawWorld(&canvas, game);
    canvas.drawImage(player, @intFromFloat(game.player.x - 3), @intFromFloat(game.player.y - 1));
    canvas.drawText("PLATFORMER", 4, 4, up.core.Color.white);
    canvas.drawText("ARROWS SPACE", 78, 4, up.core.Color.rgb(180, 205, 230));
    canvas.drawText("REACH THE FLAG", 4, 86, up.core.Color.rgb(255, 198, 74));
    return canvas;
}

fn drawWorld(canvas: *up.graphics.Canvas, game: game_mod.Game) void {
    for (game_mod.platforms) |platform| {
        canvas.fillRect(@intFromFloat(platform.x), @intFromFloat(platform.y), @intFromFloat(platform.w), @intFromFloat(platform.h), up.core.Color.rgb(55, 100, 130));
        canvas.strokeRect(@intFromFloat(platform.x), @intFromFloat(platform.y), @intFromFloat(platform.w), @intFromFloat(platform.h), up.core.Color.rgb(113, 232, 162));
    }
    canvas.fillRect(149, 54, 2, 30, up.core.Color.rgb(225, 232, 240));
    canvas.fillRect(151, 54, 7, 6, up.core.Color.rgb(255, 198, 74));
    canvas.strokeRect(@intFromFloat(game.player.x), @intFromFloat(game.player.y), game_mod.player_width, game_mod.player_height, up.core.Color.rgb(255, 198, 74));
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
