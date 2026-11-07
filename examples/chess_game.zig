//! Local two-player chess using portable GameProtocol, Canvas and authored text.
const std = @import("std");
const up = @import("unpolished-peas");
pub const rules = @import("chess/rules.zig");
pub const width: u32 = 640;
pub const height: u32 = 480;
const Color = up.core.Color;
const Canvas = up.graphics.Canvas;
const board_x = 24;
const board_y = 56;
const cell = 48;
const panel_x = 432;
const panel_w = 184;
const Menu = enum { none, draw_options, resign, restart };
const Snapshot = struct { match: rules.Match, last: ?rules.Move };
var active: ?*Game = null;

pub const Game = struct {
    allocator: std.mem.Allocator = undefined,
    assets: ?up.assets.AssetCollection = null,
    font: ?*const up.assets.Font = null,
    instructions: ?up.assets.Font.TextLayout = null,
    match: rules.Match = undefined,
    legal_moves: rules.Moves = .{},
    selected: ?u6 = null,
    cursor: u6 = 12,
    keyboard_cursor: bool = false,
    promotion: ?rules.Move = null,
    last: ?rules.Move = null,
    flipped: bool = false,
    menu: Menu = .none,
    claiming: bool = false,
    note: []const u8 = "Choose a piece to begin.",
    undo: []Snapshot = &.{},
    undo_write: usize = 0,
    undo_count: usize = 0,

    pub fn init(self: *Game, ctx: *up.core.GameContext) !void {
        const allocator = try ctx.requireAllocator();
        self.allocator = allocator;
        self.assets = up.assets.AssetCollection.init(allocator);
        errdefer self.deinit(ctx) catch {};
        self.undo = try allocator.alloc(Snapshot, 64);
        self.font = try self.assets.?.font(@embedFile("assets/fonts/SourceSans3-Regular.otf"), .{ .pixel_height = 16 });
        self.instructions = try self.font.?.layoutText(allocator, "Click a piece, then a marked square.\nArrows + Space also work.\nF: flip   U: undo\nEsc: cancel selection", .{ .max_width = panel_w, .line_spacing = 3 });
        self.restart();
        active = self;
    }
    pub fn deinit(self: *Game, _: *up.core.GameContext) !void {
        if (self.instructions) |*layout| layout.deinit();
        if (self.assets) |*assets| assets.deinit();
        self.allocator.free(self.undo);
        self.undo = &.{};
        self.instructions = null;
        self.assets = null;
        self.font = null;
        active = null;
    }
    pub fn restart(self: *Game) void {
        self.match = rules.Match.init(rules.Position.initial());
        self.last = null;
        self.undo_count = 0;
        self.undo_write = 0;
        self.cursor = 12;
        self.clearSelection();
        self.refresh();
        self.note = "Choose a piece to begin.";
    }
    fn refresh(self: *Game) void {
        self.legal_moves = if (self.match.result == .playing) self.match.position.moves() else .{};
    }
    fn clearSelection(self: *Game) void {
        self.selected = null;
        self.promotion = null;
        self.menu = .none;
        self.claiming = false;
    }
    fn remember(self: *Game) void {
        self.undo[self.undo_write] = .{ .match = self.match, .last = self.last };
        self.undo_write = (self.undo_write + 1) % self.undo.len;
        self.undo_count = @min(self.undo_count + 1, self.undo.len);
    }
    pub fn undoMove(self: *Game) void {
        self.clearSelection();
        if (self.undo_count == 0) {
            self.note = "No move to undo.";
            return;
        }
        self.undo_write = (self.undo_write + self.undo.len - 1) % self.undo.len;
        self.undo_count -= 1;
        self.match = self.undo[self.undo_write].match;
        self.last = self.undo[self.undo_write].last;
        self.refresh();
        self.note = "Move taken back.";
    }
    pub fn choose(self: *Game, sq: u6) void {
        if (self.match.result != .playing or self.promotion != null or self.menu != .none) return;
        self.cursor = sq;
        if (self.match.position.board[sq]) |piece| if (piece.side == self.match.position.turn) {
            self.selected = if (self.selected == sq) null else sq;
            self.note = if (self.selected != null) "Choose a marked square." else "Selection cleared.";
            return;
        };
        const from = self.selected orelse return;
        for (self.legal_moves.slice()) |move| if (move.from == from and move.to == sq) {
            if (move.promotion != null) {
                self.promotion = .{ .from = from, .to = sq };
                self.note = "Choose the promoted piece.";
            } else self.commit(move);
            return;
        };
        self.note = "That move is not legal.";
    }
    pub fn promote(self: *Game, kind: rules.Kind) void {
        var move = self.promotion orelse return;
        move.promotion = kind;
        if (self.match.position.legal(move)) self.commit(move);
    }
    fn commit(self: *Game, move: rules.Move) void {
        if (self.claiming) {
            if (self.match.claimWith(move)) {
                self.remember();
                self.match.result = .claimed;
                self.clearSelection();
                self.refresh();
                self.note = "Draw claimed with intended move.";
            } else {
                self.promotion = null;
                self.note = "That move does not allow a claim.";
            }
            return;
        }
        self.remember();
        self.match.play(move) catch unreachable;
        self.last = move;
        self.clearSelection();
        self.refresh();
        self.note = "Move complete.";
    }
    fn key(input: *const up.input.Input, value: up.input.Input.PhysicalKey) bool {
        for (input.extended.eventSlice()) |event| if (event.kind == .key_down and !event.repeat and event.key == value) return true;
        return false;
    }
    pub fn squareAt(self: *const Game, x: i32, y: i32) ?u6 {
        if (x < board_x or x >= board_x + cell * 8 or y < board_y or y >= board_y + cell * 8) return null;
        const column: u6 = @intCast(@divTrunc(x - board_x, cell));
        const row: u6 = @intCast(@divTrunc(y - board_y, cell));
        return if (self.flipped) row * 8 + 7 - column else (7 - row) * 8 + column;
    }
    fn buttonAt(x: i32, y: i32, index: usize) bool {
        const top = 228 + @as(i32, @intCast(index)) * 48;
        return x >= panel_x and x < panel_x + panel_w and y >= top and y < top + 40;
    }
    fn panelClick(self: *Game, index: usize) void {
        if (self.menu != .none) {
            switch (self.menu) {
                .restart => if (index == 0) {
                    self.restart();
                    return;
                },
                .resign => if (index == 0 and self.match.result == .playing) {
                    self.remember();
                    self.match.result = .resigned;
                    self.refresh();
                },
                .draw_options => {
                    if (index == 0) {
                        self.remember();
                        self.match.result = .agreed;
                        self.refresh();
                    }
                    if (index == 1) {
                        self.claiming = true;
                        self.note = "Select the intended move to claim.";
                    }
                },
                .none => unreachable,
            }
            self.menu = .none;
            return;
        }
        switch (index) {
            0 => self.menu = .restart,
            1 => self.undoMove(),
            2 => {
                self.flipped = !self.flipped;
                self.keyboard_cursor = false;
            },
            3 => if (self.match.result == .playing) {
                if (self.match.claimable()) {
                    self.remember();
                    self.match.result = .claimed;
                    self.clearSelection();
                    self.refresh();
                    self.note = "Draw claimed.";
                } else {
                    self.menu = .draw_options;
                    self.selected = null;
                }
            },
            4 => if (self.match.result == .playing) {
                self.menu = .resign;
                self.selected = null;
            },
            else => {},
        }
    }
    pub fn update(self: *Game, ctx: *up.core.GameContext, _: f32) !void {
        const input = ctx.input;
        if (key(input, .escape) or input.wasPressed(.cancel)) {
            self.clearSelection();
            self.note = "Selection cleared.";
            return;
        }
        if (key(input, .u)) {
            self.undoMove();
            return;
        }
        if (key(input, .f)) self.flipped = !self.flipped;
        if (self.promotion != null) {
            if (key(input, .q)) self.promote(.queen) else if (key(input, .r)) self.promote(.rook) else if (key(input, .b)) self.promote(.bishop) else if (key(input, .n)) self.promote(.knight);
        } else if (self.menu == .none) {
            const direction: i32 = if (self.flipped) -1 else 1;
            var x: i32 = self.cursor % 8;
            var y: i32 = self.cursor / 8;
            if (input.wasPressed(.left)) x -= direction;
            if (input.wasPressed(.right)) x += direction;
            if (input.wasPressed(.up)) y += direction;
            if (input.wasPressed(.down)) y -= direction;
            const next: u6 = @intCast(std.math.clamp(y, 0, 7) * 8 + std.math.clamp(x, 0, 7));
            if (next != self.cursor) {
                self.cursor = next;
                self.keyboard_cursor = true;
            }
            if (input.wasPressed(.action) or key(input, .enter)) self.choose(self.cursor);
        } else if (key(input, .enter)) self.panelClick(0);
        if (input.pointerWasPressed(.left)) if (input.pointer.canvas) |point| {
            const x: i32 = @intFromFloat(point.x);
            const y: i32 = @intFromFloat(point.y);
            self.keyboard_cursor = false;
            if (self.promotion != null) {
                const kinds = [_]rules.Kind{ .queen, .rook, .bishop, .knight };
                for (kinds, 0..) |kind, i| if (buttonAt(x, y, i)) self.promote(kind);
            } else if (self.squareAt(x, y)) |sq| self.choose(sq) else for (0..5) |index| if (buttonAt(x, y, index)) {
                self.panelClick(index);
                break;
            };
        };
    }
    fn text(self: *Game, canvas: *Canvas, value: []const u8, x: i32, y: i32, color: Color) void {
        self.font.?.drawText(canvas, value, x, y, color);
    }
    fn button(self: *Game, canvas: *Canvas, index: usize, label: []const u8, enabled: bool) void {
        const y = 228 + @as(i32, @intCast(index)) * 48;
        canvas.fillRect(panel_x, y, panel_w, 40, if (enabled) Color.rgb(49, 68, 70) else Color.rgb(36, 46, 48));
        self.text(canvas, label, panel_x + 12, y + 11, if (enabled) Color.rgb(235, 235, 219) else Color.rgb(137, 151, 150));
    }
    pub fn draw(self: *Game, ctx: *up.core.GameContext) !void {
        const canvas = try ctx.requireCanvas();
        canvas.clear(Color.rgb(22, 30, 33));
        self.text(canvas, "CHESS / two players", 24, 18, Color.rgb(238, 226, 195));
        self.text(canvas, "Local play", 432, 18, Color.rgb(164, 185, 177));
        const check_king = if (self.match.position.inCheck(self.match.position.turn)) self.match.position.king(self.match.position.turn) else null;
        for (0..64) |index| {
            const sq: u6 = @intCast(index);
            const column: i32 = @intCast(if (self.flipped) 7 - sq % 8 else sq % 8);
            const row: i32 = @intCast(if (self.flipped) sq / 8 else 7 - sq / 8);
            const x = board_x + column * cell;
            const y = board_y + row * cell;
            var color = if ((sq / 8 + sq % 8) % 2 == 0) Color.rgb(97, 126, 111) else Color.rgb(213, 218, 189);
            if (self.last) |last| if (sq == last.from or sq == last.to) {
                color = Color.rgb(157, 166, 105);
            };
            if (self.selected == sq) color = Color.rgb(211, 174, 87);
            if (check_king == sq) color = Color.rgb(182, 83, 69);
            canvas.fillRect(x, y, cell, cell, color);
            if (self.match.position.board[sq]) |piece| drawPiece(canvas, piece, x + 24, y + 26);
            if (self.selected) |selected| for (self.legal_moves.slice()) |move| if (move.from == selected and move.to == sq) {
                if (self.match.position.board[sq] != null) {
                    canvas.strokeRect(x + 2, y + 2, cell - 4, cell - 4, Color.rgb(239, 199, 83));
                    canvas.strokeRect(x + 3, y + 3, cell - 6, cell - 6, Color.rgb(239, 199, 83));
                } else canvas.fillCircle(x + 24, y + 24, 5, Color.rgb(40, 78, 65));
                break;
            };
            if (self.keyboard_cursor and self.cursor == sq) canvas.strokeRect(x + 1, y + 1, cell - 2, cell - 2, Color.rgb(248, 243, 220));
        }
        for (0..8) |i| {
            const file_label = [_]u8{@as(u8, 'a') + @as(u8, @intCast(if (self.flipped) 7 - i else i))};
            const rank_label = [_]u8{@as(u8, '1') + @as(u8, @intCast(if (self.flipped) i else 7 - i))};
            self.text(canvas, &file_label, 45 + @as(i32, @intCast(i)) * cell, 443, Color.rgb(177, 192, 179));
            self.text(canvas, &rank_label, 8, 72 + @as(i32, @intCast(i)) * cell, Color.rgb(177, 192, 179));
        }
        self.text(canvas, self.status(), panel_x, 57, Color.rgb(239, 214, 158));
        var buffer: [64]u8 = undefined;
        const detail = std.fmt.bufPrint(&buffer, "Move {d} / {s}", .{ self.match.position.fullmove, if (self.match.position.turn == .white) "White" else "Black" }) catch unreachable;
        self.text(canvas, detail, panel_x, 81, Color.rgb(170, 191, 182));
        self.instructions.?.draw(canvas, panel_x, 112, Color.rgb(191, 205, 194));
        // Small status uses the built-in font to fit one stable line below board.
        canvas.drawText(self.note, 24, 466, Color.rgb(204, 211, 192));
        if (self.promotion != null) {
            self.text(canvas, "Promote pawn", panel_x, 207, Color.rgb(239, 214, 158));
            for ([_][]const u8{ "Queen (Q)", "Rook (R)", "Bishop (B)", "Knight (N)" }, 0..) |label, i| self.button(canvas, i, label, true);
        } else if (self.menu != .none) {
            switch (self.menu) {
                .restart => {
                    self.button(canvas, 0, "Start a new game?", true);
                    self.button(canvas, 1, "Cancel", true);
                },
                .resign => {
                    self.button(canvas, 0, "Confirm resignation", true);
                    self.button(canvas, 1, "Cancel", true);
                },
                .draw_options => {
                    self.button(canvas, 0, "Agree a draw", true);
                    self.button(canvas, 1, "Claim next move", true);
                    self.button(canvas, 2, "Cancel", true);
                },
                .none => unreachable,
            }
        } else {
            self.button(canvas, 0, "New game", true);
            self.button(canvas, 1, "Undo (U)", self.undo_count > 0);
            self.button(canvas, 2, "Flip board (F)", true);
            self.button(canvas, 3, if (self.match.claimable()) "Claim draw" else "Draw options", self.match.result == .playing);
            self.button(canvas, 4, "Resign", self.match.result == .playing);
        }
    }
    fn status(self: *const Game) []const u8 {
        return switch (self.match.result) {
            .playing => if (self.match.position.inCheck(self.match.position.turn)) "Check!" else if (self.claiming) "Indicate claim move" else "Game in progress",
            .checkmate => if (self.match.position.turn == .white) "Checkmate / Black wins" else "Checkmate / White wins",
            .resigned => if (self.match.position.turn == .white) "Black wins / resigned" else "White wins / resigned",
            .stalemate => "Draw / stalemate",
            .material => "Draw / material",
            .repetition => "Draw / fivefold",
            .seventy_five => "Draw / 75 moves",
            .claimed => "Draw / claim",
            .agreed => "Draw / agreement",
        };
    }
};

fn shape(canvas: *Canvas, kind: rules.Kind, x: i32, y: i32, ink: Color) void {
    canvas.fillRect(x - 14, y + 12, 28, 5, ink);
    canvas.fillRect(x - 11, y + 7, 22, 6, ink);
    switch (kind) {
        .pawn => {
            canvas.fillCircle(x, y - 10, 7, ink);
            canvas.fillRect(x - 5, y - 3, 10, 12, ink);
        },
        .rook => {
            canvas.fillRect(x - 10, y - 10, 20, 18, ink);
            canvas.fillRect(x - 13, y - 15, 7, 7, ink);
            canvas.fillRect(x - 3, y - 15, 6, 7, ink);
            canvas.fillRect(x + 6, y - 15, 7, 7, ink);
        },
        .bishop => {
            canvas.fillCircle(x, y - 9, 8, ink);
            canvas.fillCircle(x, y - 17, 3, ink);
            canvas.fillTriangle(.{ .x = @floatFromInt(x), .y = @floatFromInt(y - 6) }, .{ .x = @floatFromInt(x - 10), .y = @floatFromInt(y + 10) }, .{ .x = @floatFromInt(x + 10), .y = @floatFromInt(y + 10) }, ink);
        },
        .knight => {
            canvas.fillRect(x - 8, y - 6, 14, 17, ink);
            canvas.fillTriangle(.{ .x = @floatFromInt(x - 9), .y = @floatFromInt(y - 15) }, .{ .x = @floatFromInt(x + 11), .y = @floatFromInt(y - 10) }, .{ .x = @floatFromInt(x - 6), .y = @floatFromInt(y + 8) }, ink);
            canvas.fillRect(x - 10, y - 17, 5, 7, ink);
            canvas.fillRect(x + 2, y - 12, 11, 6, ink);
        },
        .queen => {
            canvas.fillTriangle(.{ .x = @floatFromInt(x), .y = @floatFromInt(y - 14) }, .{ .x = @floatFromInt(x - 10), .y = @floatFromInt(y + 10) }, .{ .x = @floatFromInt(x + 10), .y = @floatFromInt(y + 10) }, ink);
            canvas.fillRect(x - 10, y - 9, 20, 7, ink);
            for ([_]i32{ -10, 0, 10 }) |dx| canvas.fillCircle(x + dx, y - 14, 3, ink);
        },
        .king => {
            canvas.fillCircle(x, y - 5, 9, ink);
            canvas.fillRect(x - 7, y - 3, 14, 14, ink);
            canvas.fillRect(x - 2, y - 20, 4, 15, ink);
            canvas.fillRect(x - 7, y - 17, 14, 4, ink);
        },
    }
}
fn drawPiece(canvas: *Canvas, piece: rules.Piece, x: i32, y: i32) void {
    const edge = if (piece.side == .white) Color.rgb(35, 43, 43) else Color.rgb(232, 229, 208);
    const fill = if (piece.side == .white) Color.rgb(248, 239, 217) else Color.rgb(29, 39, 44);
    for ([_][2]i32{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } }) |offset| shape(canvas, piece.kind, x + offset[0], y + offset[1], edge);
    shape(canvas, piece.kind, x, y, fill);
    if (piece.kind == .bishop) canvas.line(x - 1, y - 14, x + 4, y - 9, edge);
    if (piece.kind == .knight) canvas.fillCircle(x + 4, y - 10, 1, edge);
}

// Internal browser fixture observation; not part of the Peas API.
pub export fn chess_metric(index: u32) i32 {
    const game = active orelse return -1;
    return switch (index) {
        0 => @intFromEnum(game.match.position.turn),
        1 => @intFromEnum(game.match.result),
        2 => @intCast(game.match.position.fullmove),
        3 => if (game.selected) |sq| sq else -1,
        4 => @intCast(game.undo_count),
        5 => @intFromBool(game.flipped),
        6 => if (game.promotion) |move| move.to else -1,
        7 => @intFromEnum(game.menu),
        else => -1,
    };
}
pub export fn chess_piece(sq: u32) i32 {
    const game = active orelse return -1;
    if (sq >= 64) return -1;
    const piece = game.match.position.board[sq] orelse return 0;
    return 1 + @as(i32, @intFromEnum(piece.kind)) + (if (piece.side == .black) @as(i32, 6) else 0);
}
