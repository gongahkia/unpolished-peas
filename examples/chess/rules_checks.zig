const std = @import("std");
const chess = @import("rules.zig");
const Position = chess.Position;
fn require(ok: bool) !void {
    if (!ok) return error.ChessRuleMismatch;
}
pub fn move(from: *const [2]u8, to: *const [2]u8) chess.Move {
    return .{ .from = chess.square(from), .to = chess.square(to) };
}
// Standard perft positions also used by the official Stockfish regression
// suite. This is an independent rules implementation, not Stockfish code.
pub fn verify() !u64 {
    const cases = [_]struct { fen: []const u8, depth: u8, nodes: u64 }{
        .{ .fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", .depth = 4, .nodes = 197281 },
        .{ .fen = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1", .depth = 3, .nodes = 97862 },
        .{ .fen = "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1", .depth = 4, .nodes = 43238 },
        .{ .fen = "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1", .depth = 3, .nodes = 9467 },
        .{ .fen = "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8", .depth = 3, .nodes = 62379 },
        .{ .fen = "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10", .depth = 3, .nodes = 89890 },
    };
    var nodes: u64 = 0;
    for (cases) |case| {
        const actual = chess.perft(try Position.fromFen(case.fen), case.depth);
        if (actual != case.nodes) return error.ChessPerftMismatch;
        nodes += actual;
    }
    var position = try Position.fromFen("k3r3/8/8/3pP3/8/8/8/4K3 w - d6 0 1");
    try require(!position.legal(move("e5", "d6")));
    var no_ep = position;
    no_ep.ep = null;
    try require(std.mem.eql(u8, &position.identity(), &no_ep.identity()));
    position = try Position.fromFen("4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1");
    try require(position.legal(move("e5", "d6")));
    no_ep = position;
    no_ep.ep = null;
    try require(!std.mem.eql(u8, &position.identity(), &no_ep.identity()));
    position.applyUnchecked(move("e5", "d6"));
    try require(position.board[chess.square("d5")] == null and position.ep == null and position.halfmoves == 0);
    position = try Position.fromFen("4k3/8/8/8/2b5/8/8/R3K2R w KQ - 0 1");
    try require(!position.legal(move("e1", "g1")) and position.legal(move("e1", "c1")));
    position.applyUnchecked(move("e1", "c1"));
    try require(position.board[chess.square("d1")].?.kind == .rook and position.board[chess.square("a1")] == null and position.castling == 0);
    position = try Position.fromFen("4r1k1/8/8/8/8/8/4R3/4K3 w - - 0 1");
    try require(!position.legal(move("e2", "f2")) and position.legal(move("e2", "e8")));
    position = try Position.fromFen("4k3/P7/8/8/8/8/8/4K3 w - - 0 1");
    try require(!position.legal(move("a7", "a8")));
    for ([_]chess.Kind{ .queen, .rook, .bishop, .knight }) |kind| {
        var promotion = move("a7", "a8");
        promotion.promotion = kind;
        try require(position.legal(promotion));
        var next = position;
        next.applyUnchecked(promotion);
        try require(next.board[chess.square("a8")].?.kind == kind);
    }
    var match = chess.Match.init(Position.initial());
    for ([_]chess.Move{ move("f2", "f3"), move("e7", "e5"), move("g2", "g4"), move("d8", "h4") }) |m| try match.play(m);
    try require(match.result == .checkmate and match.position.turn == .white);
    try require(chess.Match.init(try Position.fromFen("k7/8/1QK5/8/8/8/8/8 b - - 0 1")).result == .stalemate);
    try require(chess.Match.init(try Position.fromFen("7k/8/8/8/8/2K5/8/8 w - - 0 1")).result == .material);
    match = chess.Match.init(Position.initial());
    for (0..4) |cycle| {
        for ([_]chess.Move{ move("g1", "f3"), move("g8", "f6"), move("f3", "g1"), move("f6", "g8") }) |m| try match.play(m);
        if (cycle == 1) try require(match.claimable() and match.result == .playing);
    }
    try require(match.result == .repetition);
    match = chess.Match.init(try Position.fromFen("k6r/8/8/8/8/8/8/4K1N1 w - - 99 50"));
    try require(!match.claimable() and match.claimWith(move("g1", "f3")));
    try match.play(move("g1", "f3"));
    try require(match.claimable());
    match = chess.Match.init(try Position.fromFen("k6r/8/8/8/8/8/8/4K1N1 w - - 149 75"));
    try match.play(move("g1", "f3"));
    try require(match.result == .seventy_five);
    match = chess.Match.init(try Position.fromFen("7k/5Q2/5K2/8/8/8/8/8 w - - 149 75"));
    try match.play(move("f7", "g7"));
    try require(match.result == .checkmate);
    return nodes;
}
test "standard move-tree references and special moves, pins, mate and draw rules" {
    try std.testing.expectEqual(@as(u64, 500117), try verify());
}
test "FEN setup rejects incomplete and malformed boards" {
    for ([_][]const u8{ "8/8/8/8/8/8/8/8 w - -", "9/8/8/8/8/8/8/K6k w - -", "8/8/8/8/8/8/8/K6k x - -", "8/8/8/8/8/8/8/K6k w - z6" }) |fen| try std.testing.expectError(error.BadFen, Position.fromFen(fen));
}
