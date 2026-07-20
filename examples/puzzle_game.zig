const std = @import("std");
const up = @import("unpolished-peas");

pub const width = 160;
pub const height = 96;
pub const columns = 3;
pub const rows = 3;
pub const cell_count = columns * rows;
pub const actions = [_]up.input.Action{
    .{ .name = "left", .binding = .{ .key = .left } },
    .{ .name = "right", .binding = .{ .key = .right } },
    .{ .name = "up", .binding = .{ .key = .up } },
    .{ .name = "down", .binding = .{ .key = .down } },
    .{ .name = "toggle", .binding = .{ .key = .action } },
};

pub const Event = struct { toggled: bool = false, solved: bool = false };
pub const Diagnostics = struct { selected: usize, lit: usize, moves: u32, solved: bool };

pub const Game = struct {
    cells: [cell_count]bool = .{ true, false, true, false, true, false, true, false, true },
    selected: usize = 4,
    moves: u32 = 0,
    toggle_was_down: bool = false,

    pub fn step(self: *Game, input: up.input.Input) Event {
        const bindings = up.input.ActionMap{ .actions = &actions };
        const horizontal = bindings.value(input, "game", "right") - bindings.value(input, "game", "left");
        const vertical = bindings.value(input, "game", "down") - bindings.value(input, "game", "up");
        if (horizontal < 0 and self.selected % columns > 0) self.selected -= 1;
        if (horizontal > 0 and self.selected % columns + 1 < columns) self.selected += 1;
        if (vertical < 0 and self.selected >= columns) self.selected -= columns;
        if (vertical > 0 and self.selected + columns < cell_count) self.selected += columns;
        const toggle_down = bindings.value(input, "game", "toggle") != 0;
        const toggled = toggle_down and !self.toggle_was_down;
        self.toggle_was_down = toggle_down;
        if (toggled) self.toggle(self.selected);
        return .{ .toggled = toggled, .solved = self.solved() };
    }

    pub fn toggle(self: *Game, index: usize) void {
        for ([_]i32{ 0, -@as(i32, columns), @as(i32, columns), -1, 1 }) |offset| {
            const candidate = @as(i32, @intCast(index)) + offset;
            if (candidate < 0 or candidate >= cell_count) continue;
            const cell: usize = @intCast(candidate);
            if ((offset == -1 and cell / columns != index / columns) or (offset == 1 and cell / columns != index / columns)) continue;
            self.cells[cell] = !self.cells[cell];
        }
        self.moves += 1;
    }

    pub fn solved(self: Game) bool {
        for (self.cells) |cell| if (cell) return false;
        return true;
    }

    pub fn diagnostics(self: Game) Diagnostics {
        var lit: usize = 0;
        for (self.cells) |cell| {
            if (cell) lit += 1;
        }
        return .{ .selected = self.selected, .lit = lit, .moves = self.moves, .solved = self.solved() };
    }
};

test "puzzle toggles only the selected cross" {
    var game = Game{};
    game.toggle(4);
    try std.testing.expectEqualSlices(bool, &.{ true, true, true, true, false, true, true, true, true }, &game.cells);
    try std.testing.expectEqual(@as(u32, 1), game.moves);
}

test "puzzle action map is deterministic and bounds selection" {
    var input = up.input.Input{};
    input.set(.left, true);
    var a = Game{};
    var b = Game{};
    _ = a.step(input);
    _ = b.step(input);
    input.set(.left, false);
    input.set(.action, true);
    const event = a.step(input);
    _ = b.step(input);
    try std.testing.expect(event.toggled);
    try std.testing.expectEqualDeep(a, b);
    try std.testing.expectEqual(@as(usize, 3), a.selected);
}
