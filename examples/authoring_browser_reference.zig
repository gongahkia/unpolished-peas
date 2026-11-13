//! Native CPU pixels for the actual compiled authored-font menu/dialogue.
const std = @import("std");
const up = @import("unpolished-peas");
const font_game = @import("font_layout_game.zig");

fn capture(runner: anytype, directory: std.fs.Dir, path: []const u8) !void {
    try runner.draw(0);
    try directory.writeFile(.{ .sub_path = path, .data = std.mem.sliceAsBytes(runner.canvas.pixels) });
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 2) return error.ExpectedReferenceDirectory;
    try std.fs.cwd().makePath(args[1]);
    var directory = try std.fs.cwd().openDir(args[1], .{});
    defer directory.close();
    const runner = try up.testSupport.HeadlessGameRunner(font_game.Game).init(allocator, font_game.width, font_game.height);
    defer runner.deinit();
    runner.canvas.detachTrace();
    try capture(runner, directory, "font-initial.rgba");
    var input = up.input.Input{};
    input.set(.down, true);
    try runner.step(input.snapshot(), 1.0 / 60.0);
    try capture(runner, directory, "font-selected.rgba");
    input.beginFrame();
    input.set(.down, false);
    input.set(.action, true);
    try runner.step(input.snapshot(), 1.0 / 60.0);
    try capture(runner, directory, "font-dialogue.rgba");
    const font = runner.game.font.?;
    const json = try std.json.Stringify.valueAlloc(allocator, .{
        .width = font_game.width,
        .height = font_game.height,
        .wide = try font.measureText("WWW", .{}),
        .narrow = try font.measureText("iii", .{}),
        .dialogue_lines = runner.game.dialogue[1].?.metrics.lines,
    }, .{});
    defer allocator.free(json);
    try directory.writeFile(.{ .sub_path = "font.json", .data = json });
}
