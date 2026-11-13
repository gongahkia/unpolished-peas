const std = @import("std");
const up = @import("unpolished-peas");
const chess = @import("chess_game.zig");
const checks = @import("chess/rules_checks.zig");
pub export fn chess_rules_check() u64 {
    return checks.verify() catch 0;
}
pub fn main() !void {
    if (chess_rules_check() != 500117) return error.ChessRulesFailed;
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 2) return error.ExpectedOutputDirectory;
    var directory = try std.fs.cwd().openDir(args[1], .{});
    defer directory.close();
    const runner = try up.testSupport.HeadlessGameRunner(chess.Game).init(allocator, chess.width, chess.height);
    defer runner.deinit();
    runner.canvas.detachTrace();
    try runner.draw(0);
    try directory.writeFile(.{ .sub_path = "initial.rgba", .data = std.mem.sliceAsBytes(runner.canvas.pixels) });
    for ([_]chess.rules.Move{ checks.move("f2", "f3"), checks.move("e7", "e5"), checks.move("g2", "g4"), checks.move("d8", "h4") }) |move| {
        runner.game.choose(move.from);
        runner.game.choose(move.to);
    }
    try runner.draw(0);
    try directory.writeFile(.{ .sub_path = "mate.rgba", .data = std.mem.sliceAsBytes(runner.canvas.pixels) });
}
