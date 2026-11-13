//! Example-owned standard chess rules. No engine/platform dependencies.
const std = @import("std");
pub const Side = enum {
    white,
    black,
    pub fn other(self: Side) Side {
        return if (self == .white) .black else .white;
    }
};
pub const Kind = enum { pawn, knight, bishop, rook, queen, king };
pub const Piece = struct { side: Side, kind: Kind };
pub const Move = struct { from: u6, to: u6, promotion: ?Kind = null };
pub const Result = enum { playing, checkmate, stalemate, material, repetition, seventy_five, claimed, agreed, resigned };
pub const Moves = struct {
    items: [256]Move = undefined,
    len: usize = 0,
    pub fn slice(self: *const Moves) []const Move {
        return self.items[0..self.len];
    }
    fn add(self: *Moves, move: Move) void {
        std.debug.assert(self.len < self.items.len);
        self.items[self.len] = move;
        self.len += 1;
    }
};
pub fn square(name: *const [2]u8) u6 {
    return @intCast((name[1] - '1') * 8 + name[0] - 'a');
}
fn file(sq: u6) i32 {
    return @intCast(sq % 8);
}
fn rank(sq: u6) i32 {
    return @intCast(sq / 8);
}
fn at(x: i32, y: i32) ?u6 {
    return if (x >= 0 and x < 8 and y >= 0 and y < 8) @intCast(y * 8 + x) else null;
}
fn bit(side: Side, king_side: bool) u4 {
    return @as(u4, 1) << @as(u2, @intCast((if (side == .white) @as(u3, 0) else 2) + @as(u3, if (king_side) 0 else 1)));
}

pub const Position = struct {
    board: [64]?Piece = .{null} ** 64,
    turn: Side = .white,
    castling: u4 = 0,
    ep: ?u6 = null,
    halfmoves: u16 = 0,
    fullmove: u32 = 1,

    pub fn initial() Position {
        return fromFen("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1") catch unreachable;
    }
    pub fn fromFen(fen: []const u8) !Position {
        var fields = std.mem.tokenizeScalar(u8, fen, ' ');
        const placement = fields.next() orelse return error.BadFen;
        var position = Position{};
        var x: i32 = 0;
        var y: i32 = 7;
        for (placement) |c| {
            if (c == '/') {
                if (x != 8 or y == 0) return error.BadFen;
                x = 0;
                y -= 1;
                continue;
            }
            if (c >= '1' and c <= '8') {
                x += c - '0';
                if (x > 8) return error.BadFen;
                continue;
            }
            const sq = at(x, y) orelse return error.BadFen;
            const kind: Kind = switch (std.ascii.toLower(c)) {
                'p' => .pawn,
                'n' => .knight,
                'b' => .bishop,
                'r' => .rook,
                'q' => .queen,
                'k' => .king,
                else => return error.BadFen,
            };
            position.board[sq] = .{ .side = if (std.ascii.isUpper(c)) .white else .black, .kind = kind };
            x += 1;
        }
        if (x != 8 or y != 0) return error.BadFen;
        const turn = fields.next() orelse return error.BadFen;
        position.turn = if (std.mem.eql(u8, turn, "w")) .white else if (std.mem.eql(u8, turn, "b")) .black else return error.BadFen;
        const rights = fields.next() orelse return error.BadFen;
        for (rights) |c| position.castling |= switch (c) {
            'K' => bit(.white, true),
            'Q' => bit(.white, false),
            'k' => bit(.black, true),
            'q' => bit(.black, false),
            '-' => 0,
            else => return error.BadFen,
        };
        const ep = fields.next() orelse return error.BadFen;
        if (!std.mem.eql(u8, ep, "-")) {
            if (ep.len != 2 or ep[0] < 'a' or ep[0] > 'h' or (ep[1] != '3' and ep[1] != '6')) return error.BadFen;
            position.ep = square(ep[0..2]);
        }
        if (fields.next()) |value| position.halfmoves = try std.fmt.parseInt(u16, value, 10);
        if (fields.next()) |value| position.fullmove = try std.fmt.parseInt(u32, value, 10);
        if (fields.next() != null or position.king(.white) == null or position.king(.black) == null) return error.BadFen;
        return position;
    }
    pub fn king(self: Position, side: Side) ?u6 {
        for (self.board, 0..) |piece, i| if (piece) |p| {
            if (p.kind == .king and p.side == side) return @intCast(i);
        };
        return null;
    }
    fn clearRay(self: Position, from: u6, to: u6) bool {
        const dx = std.math.sign(file(to) - file(from));
        const dy = std.math.sign(rank(to) - rank(from));
        var x = file(from) + dx;
        var y = rank(from) + dy;
        while (x != file(to) or y != rank(to)) : ({
            x += dx;
            y += dy;
        }) {
            const sq = at(x, y) orelse return false;
            if (self.board[sq] != null) return false;
        }
        return true;
    }
    pub fn attacked(self: Position, target: u6, by: Side) bool {
        for (self.board, 0..) |piece, index| if (piece) |p| {
            if (p.side != by) continue;
            const from: u6 = @intCast(index);
            const dx = file(target) - file(from);
            const dy = rank(target) - rank(from);
            const ax = @abs(dx);
            const ay = @abs(dy);
            const hits = switch (p.kind) {
                .pawn => ax == 1 and dy == (if (by == .white) @as(i32, 1) else -1),
                .knight => (ax == 1 and ay == 2) or (ax == 2 and ay == 1),
                .king => @max(ax, ay) == 1,
                .bishop => ax == ay and ax != 0 and self.clearRay(from, target),
                .rook => ((dx == 0) != (dy == 0)) and self.clearRay(from, target),
                .queen => (ax == ay or ((dx == 0) != (dy == 0))) and (ax + ay > 0) and self.clearRay(from, target),
            };
            if (hits) return true;
        };
        return false;
    }
    pub fn inCheck(self: Position, side: Side) bool {
        return self.attacked(self.king(side) orelse return true, side.other());
    }
    fn canCastle(self: Position, side: Side, king_side: bool) bool {
        if (self.castling & bit(side, king_side) == 0 or self.inCheck(side)) return false;
        const y: i32 = if (side == .white) 0 else 7;
        const rook = self.board[at(if (king_side) 7 else 0, y).?] orelse return false;
        if (rook.kind != .rook or rook.side != side) return false;
        const first: i32 = if (king_side) 5 else 1;
        const last: i32 = if (king_side) 6 else 3;
        var x = first;
        while (x <= last) : (x += 1) if (self.board[at(x, y).?] != null) return false;
        return !self.attacked(at(if (king_side) 5 else 3, y).?, side.other()) and !self.attacked(at(if (king_side) 6 else 2, y).?, side.other());
    }
    pub fn legal(self: Position, move: Move) bool {
        if (move.from == move.to) return false;
        const piece = self.board[move.from] orelse return false;
        if (piece.side != self.turn) return false;
        if (self.board[move.to]) |p| if (p.side == piece.side or p.kind == .king) return false;
        const dx = file(move.to) - file(move.from);
        const dy = rank(move.to) - rank(move.from);
        const ax = @abs(dx);
        const ay = @abs(dy);
        const promotion_rank: i32 = if (piece.side == .white) 7 else 0;
        const promotes = piece.kind == .pawn and rank(move.to) == promotion_rank;
        if (promotes) {
            const promoted = move.promotion orelse return false;
            if (promoted == .pawn or promoted == .king) return false;
        } else if (move.promotion != null) return false;
        const pseudo = switch (piece.kind) {
            .knight => (ax == 1 and ay == 2) or (ax == 2 and ay == 1),
            .bishop => ax == ay and self.clearRay(move.from, move.to),
            .rook => ((dx == 0) != (dy == 0)) and self.clearRay(move.from, move.to),
            .queen => (ax == ay or ((dx == 0) != (dy == 0))) and self.clearRay(move.from, move.to),
            .king => @max(ax, ay) == 1 or (file(move.from) == 4 and rank(move.from) == (if (piece.side == .white) @as(i32, 0) else 7) and dy == 0 and ax == 2 and self.canCastle(piece.side, dx > 0)),
            .pawn => blk: {
                const direction: i32 = if (piece.side == .white) 1 else -1;
                if (dx == 0 and self.board[move.to] == null) {
                    if (dy == direction) break :blk true;
                    if (dy == direction * 2 and rank(move.from) == (if (piece.side == .white) @as(i32, 1) else 6) and self.board[at(file(move.from), rank(move.from) + direction).?] == null) break :blk true;
                }
                if (ax != 1 or dy != direction) break :blk false;
                if (self.board[move.to] != null) break :blk true;
                if (self.ep != move.to) break :blk false;
                const victim = self.board[at(file(move.to), rank(move.from)).?] orelse break :blk false;
                break :blk victim.kind == .pawn and victim.side != piece.side;
            },
        };
        if (!pseudo) return false;
        var next = self;
        next.applyUnchecked(move);
        return !next.inCheck(piece.side);
    }
    fn revokeRook(self: *Position, sq: u6) void {
        switch (sq) {
            0 => self.castling &= ~bit(.white, false),
            7 => self.castling &= ~bit(.white, true),
            56 => self.castling &= ~bit(.black, false),
            63 => self.castling &= ~bit(.black, true),
            else => {},
        }
    }
    pub fn applyUnchecked(self: *Position, move: Move) void {
        var piece = self.board[move.from].?;
        const capture = self.board[move.to] != null or (piece.kind == .pawn and file(move.from) != file(move.to));
        self.halfmoves = if (piece.kind == .pawn or capture) 0 else self.halfmoves +| 1;
        if (piece.kind == .pawn and self.ep == move.to and self.board[move.to] == null and file(move.from) != file(move.to)) self.board[at(file(move.to), rank(move.from)).?] = null;
        self.ep = if (piece.kind == .pawn and @abs(rank(move.to) - rank(move.from)) == 2) at(file(move.from), @divTrunc(rank(move.from) + rank(move.to), 2)) else null;
        if (piece.kind == .king) {
            self.castling &= ~(bit(piece.side, true) | bit(piece.side, false));
            if (@abs(file(move.to) - file(move.from)) == 2) {
                const rook_from = at(if (file(move.to) == 6) 7 else 0, rank(move.from)).?;
                const rook_to = at(if (file(move.to) == 6) 5 else 3, rank(move.from)).?;
                self.board[rook_to] = self.board[rook_from];
                self.board[rook_from] = null;
            }
        }
        if (piece.kind == .rook) self.revokeRook(move.from);
        if (self.board[move.to]) |victim| if (victim.kind == .rook) self.revokeRook(move.to);
        if (move.promotion) |promotion| piece.kind = promotion;
        self.board[move.to] = piece;
        self.board[move.from] = null;
        if (self.turn == .black) self.fullmove +|= 1;
        self.turn = self.turn.other();
    }
    pub fn moves(self: Position) Moves {
        var result = Moves{};
        for (self.board, 0..) |piece, from| if (piece) |p| {
            if (p.side != self.turn) continue;
            for (0..64) |to| {
                const move = Move{ .from = @intCast(from), .to = @intCast(to) };
                if (p.kind == .pawn and to / 8 == (if (p.side == .white) @as(usize, 7) else 0)) {
                    for ([_]Kind{ .queen, .rook, .bishop, .knight }) |promotion| {
                        var promoted = move;
                        promoted.promotion = promotion;
                        if (self.legal(promoted)) result.add(promoted);
                    }
                } else if (self.legal(move)) result.add(move);
            }
        };
        return result;
    }
    pub fn insufficient(self: Position) bool {
        var minors: usize = 0;
        var knights: usize = 0;
        var bishop_color: ?u1 = null;
        for (self.board, 0..) |piece, i| if (piece) |p| switch (p.kind) {
            .king => {},
            .pawn, .rook, .queen => return false,
            .knight => {
                minors += 1;
                knights += 1;
            },
            .bishop => {
                minors += 1;
                const color: u1 = @intCast((i / 8 + i % 8) % 2);
                if (bishop_color) |previous| {
                    if (color != previous) return false;
                } else bishop_color = color;
            },
        };
        return minors <= 1 or (knights == 0 and bishop_color != null);
    }
    // Collision-free repetition identity, including only legally usable EP.
    pub fn identity(self: Position) [67]u8 {
        var bytes: [67]u8 = .{0} ** 67;
        for (self.board, 0..) |piece, i| if (piece) |p| {
            bytes[i] = 1 + @as(u8, @intFromEnum(p.kind)) + (if (p.side == .black) @as(u8, 6) else 0);
        };
        bytes[64] = @intFromEnum(self.turn);
        bytes[65] = self.castling;
        if (self.ep) |ep| {
            const from_rank = rank(ep) + (if (self.turn == .white) @as(i32, -1) else 1);
            for ([_]i32{ -1, 1 }) |dx| if (at(file(ep) + dx, from_rank)) |from| {
                if (self.board[from]) |p| if (p.kind == .pawn and p.side == self.turn and self.legal(.{ .from = from, .to = ep })) {
                    bytes[66] = @as(u8, ep) + 1;
                    break;
                };
            };
        }
        return bytes;
    }
};

pub const Match = struct {
    position: Position,
    result: Result = .playing,
    // Pawn moves/captures reset history. The automatic 75-move rule bounds
    // any intervening reversible sequence to 150 plies plus its start.
    identities: [151][67]u8 = undefined,
    identity_count: usize = 1,
    pub fn init(position: Position) Match {
        var result = Match{ .position = position };
        result.identities[0] = position.identity();
        result.adjudicate();
        return result;
    }
    pub fn repetitions(self: *const Match) usize {
        const key = self.position.identity();
        var count: usize = 0;
        for (self.identities[0..self.identity_count]) |previous| if (std.mem.eql(u8, &key, &previous)) {
            count += 1;
        };
        return count;
    }
    pub fn claimable(self: *const Match) bool {
        return self.result == .playing and (self.position.halfmoves >= 100 or self.repetitions() >= 3);
    }
    pub fn claimWith(self: *const Match, move: Move) bool {
        if (self.result != .playing or !self.position.legal(move)) return false;
        var next = self.*;
        next.play(move) catch return false;
        return next.position.halfmoves >= 100 or next.repetitions() >= 3;
    }
    pub fn play(self: *Match, move: Move) !void {
        if (self.result != .playing or !self.position.legal(move)) return error.IllegalMove;
        self.position.applyUnchecked(move);
        if (self.position.halfmoves == 0) self.identity_count = 0;
        std.debug.assert(self.identity_count < self.identities.len);
        self.identities[self.identity_count] = self.position.identity();
        self.identity_count += 1;
        self.adjudicate();
    }
    fn adjudicate(self: *Match) void {
        const legal_moves = self.position.moves();
        self.result = if (legal_moves.len == 0) (if (self.position.inCheck(self.position.turn)) .checkmate else .stalemate) else if (self.position.insufficient()) .material else if (self.position.halfmoves >= 150) .seventy_five else if (self.repetitions() >= 5) .repetition else .playing;
    }
};

pub fn perft(position: Position, depth: u8) u64 {
    if (depth == 0) return 1;
    var count: u64 = 0;
    const legal_moves = position.moves();
    for (legal_moves.slice()) |move| {
        var next = position;
        next.applyUnchecked(move);
        count += perft(next, depth - 1);
    }
    return count;
}
