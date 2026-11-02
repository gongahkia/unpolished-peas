const std = @import("std");
const up = @import("unpolished-peas");
const game_mod = @import("puzzle_game.zig");

const golden_path = "proof-puzzle-reference.png";
const expected_hash: u64 = 0x29720eb30140bd40;
const diagnostics_path = "zig-out/scenes/puzzle";
const board_x = 45;
const board_y = 24;
const cell_size = 20;
const cell_gap = 4;

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
    const marker = try assets.loadImage("ball.png");
    var canvas = try renderPuzzle(allocator, try assets.tryImage(marker));
    defer canvas.deinit();
    if (update_golden) return writeGolden(allocator, &assets, golden_path, canvas);
    try assertGolden(allocator, &assets, golden_path, canvas, expected_hash, diagnostics_path);
}

fn renderPuzzle(allocator: std.mem.Allocator, marker: up.assets.Image) !up.graphics.Canvas {
    var game = game_mod.Game{};
    var input = up.input.Input{};
    input.set(.left, true);
    _ = game.step(input);
    input.set(.left, false);
    input.set(.action, true);
    _ = game.step(input);
    input.set(.action, false);
    _ = game.step(input);
    var canvas = try up.graphics.Canvas.init(allocator, game_mod.width, game_mod.height);
    canvas.clear(up.core.Color.rgb(13, 18, 30));
    drawBoard(&canvas, game);
    const selected = cellPosition(game.selected);
    canvas.drawImage(marker, selected.x + 2, selected.y + 2);
    canvas.drawText("LIGHTS OUT", 4, 4, up.core.Color.white);
    canvas.drawText("ARROWS SPACE", 82, 4, up.core.Color.rgb(180, 205, 230));
    canvas.drawText("TOGGLE THE CROSS", 4, 86, up.core.Color.rgb(255, 198, 74));
    return canvas;
}

fn drawBoard(canvas: *up.graphics.Canvas, game: game_mod.Game) void {
    for (game.cells, 0..) |lit, index| {
        const position = cellPosition(index);
        canvas.fillRect(position.x, position.y, cell_size, cell_size, if (lit) up.core.Color.rgb(113, 232, 162) else up.core.Color.rgb(31, 47, 68));
        canvas.strokeRect(position.x, position.y, cell_size, cell_size, if (index == game.selected) up.core.Color.rgb(255, 198, 74) else up.core.Color.rgb(91, 124, 158));
    }
}

fn cellPosition(index: usize) struct { x: i32, y: i32 } {
    return .{
        .x = board_x + @as(i32, @intCast(index % game_mod.columns)) * (cell_size + cell_gap),
        .y = board_y + @as(i32, @intCast(index / game_mod.columns)) * (cell_size + cell_gap),
    };
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
