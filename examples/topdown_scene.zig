const std = @import("std");
const up = @import("unpolished-peas").api;
const game_mod = @import("topdown_game.zig");
const expected_hash: u64 = 0x95b619e80d995c40;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var assets = try up.AssetStore.initExecutable(allocator);
    defer assets.deinit();
    const map = try assets.loadTileMap("topdown.upmap");
    const player = try assets.loadPng("ball.png");
    var game = game_mod.Game{};
    var input = up.Input{};
    input.set(.right, true);
    input.set(.down, true);
    var frame: u32 = 0;
    while (frame < 60) : (frame += 1) _ = game.step(input, 1.0 / 60.0);
    var canvas = try up.Canvas.init(allocator, game_mod.width, game_mod.height);
    defer canvas.deinit();
    canvas.clear(up.Color.rgb(10, 18, 26));
    const camera = up.Camera2D{ .position = .{ .x = 80, .y = 48 }, .zoom = 1 };
    assets.drawTileMap(map, &camera, &canvas, 0);
    canvas.drawImage(assets.image(player), @intFromFloat(game.player.x - 8), @intFromFloat(game.player.y - 8));
    canvas.drawText("TOPDOWN", 4, 4, up.Color.white);
    var buffer: [32]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buffer);
    if (up.testSupport.canvasHash(canvas) != expected_hash) return error.TopDownSceneMismatch;
    try writer.interface.print("{x}\n", .{expected_hash});
    try writer.interface.flush();
}
