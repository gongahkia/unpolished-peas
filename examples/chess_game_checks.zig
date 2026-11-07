const std = @import("std");
const up = @import("unpolished-peas");
const chess = @import("chess_game.zig");
const Counter = @import("render-counter").CountingAllocator;
const checks = @import("chess/rules_checks.zig");

fn play(game: *chess.Game, from: *const [2]u8, to: *const [2]u8) void {
    game.choose(chess.rules.square(from));
    game.choose(chess.rules.square(to));
}
fn setup(game: *chess.Game, fen: []const u8) !void {
    game.match = chess.rules.Match.init(try chess.rules.Position.fromFen(fen));
    game.legal_moves = game.match.position.moves();
    game.selected = null;
    game.promotion = null;
}
test "portable chess plays a complete mate, rejects illegal moves and undoes the result without drawing allocations" {
    var counter = Counter.init(std.testing.allocator);
    const runner = try up.testSupport.HeadlessGameRunner(chess.Game).init(counter.allocator(), chess.width, chess.height);
    defer runner.deinit();
    runner.canvas.detachTrace();
    counter.reset();
    play(&runner.game, "e2", "e5");
    try std.testing.expectEqual(chess.rules.Side.white, runner.game.match.position.turn);
    runner.game.selected = null;
    play(&runner.game, "f2", "f3");
    play(&runner.game, "e7", "e5");
    play(&runner.game, "g2", "g4");
    play(&runner.game, "d8", "h4");
    try std.testing.expectEqual(chess.rules.Result.checkmate, runner.game.match.result);
    try runner.draw(0);
    runner.game.undoMove();
    try std.testing.expectEqual(chess.rules.Result.playing, runner.game.match.result);
    try std.testing.expectEqual(chess.rules.Side.black, runner.game.match.position.turn);
    try std.testing.expectEqual(@as(usize, 3), runner.game.undo_count);
    try runner.draw(0);
    try std.testing.expectEqual(@as(u64, 0), counter.allocation_events);
}
test "promotion waits for a player choice and undo restores castling and en passant" {
    const runner = try up.testSupport.HeadlessGameRunner(chess.Game).init(std.testing.allocator, chess.width, chess.height);
    defer runner.deinit();
    runner.canvas.detachTrace();
    try setup(&runner.game, "4k3/P7/8/8/8/8/8/4K3 w - - 0 1");
    play(&runner.game, "a7", "a8");
    try std.testing.expect(runner.game.promotion != null);
    try std.testing.expectEqual(chess.rules.Side.white, runner.game.match.position.turn);
    runner.game.promote(.knight);
    try std.testing.expectEqual(chess.rules.Kind.knight, runner.game.match.position.board[chess.rules.square("a8")].?.kind);
    runner.game.undoMove();
    try std.testing.expectEqual(chess.rules.Kind.pawn, runner.game.match.position.board[chess.rules.square("a7")].?.kind);
    try setup(&runner.game, "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1");
    play(&runner.game, "e1", "g1");
    runner.game.undoMove();
    try std.testing.expectEqual(@as(u4, 15), runner.game.match.position.castling);
    try setup(&runner.game, "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1");
    play(&runner.game, "e5", "d6");
    runner.game.undoMove();
    try std.testing.expectEqual(chess.rules.square("d6"), runner.game.match.position.ep.?);
    try std.testing.expect(runner.game.match.position.board[chess.rules.square("d5")] != null);
}
test "mouse coordinates and flipped orientation preserve board identity" {
    const runner = try up.testSupport.HeadlessGameRunner(chess.Game).init(std.testing.allocator, chess.width, chess.height);
    defer runner.deinit();
    runner.canvas.detachTrace();
    try std.testing.expectEqual(chess.rules.square("a8"), runner.game.squareAt(25, 57).?);
    try std.testing.expect(runner.game.squareAt(23, 56) == null);
    runner.game.flipped = true;
    try std.testing.expectEqual(chess.rules.square("h1"), runner.game.squareAt(25, 57).?);
    var input = up.input.Input{};
    input.setPointerPosition(.{}, .{}, .{ .x = 24 + 3 * 48 + 24, .y = 56 + 1 * 48 + 24 });
    input.setPointerButton(.left, true);
    try runner.step(input.snapshot(), 1.0 / 60.0);
    try std.testing.expectEqual(chess.rules.square("e2"), runner.game.selected.?);
}
test "standard chess rules remain covered alongside the compiled game" {
    try std.testing.expectEqual(@as(u64, 500117), try checks.verify());
}
