const std = @import("std");
const up = @import("unpolished-peas");

fn togglesAction(allocator: std.mem.Allocator) !bool {
    const definitions = [_]up.input.Action{
        .{ .name = "toggle", .binding = .{ .key = .action } },
    };
    var actions = try up.input.ActionMap.init(allocator, &definitions);
    defer actions.deinit();
    var input = up.input.Input{};
    input.set(.action, true);
    actions.update(input);
    return actions.isDown("game", "toggle") and actions.value(input, "game", "toggle") == 1;
}

pub fn main() !void {
    if (!try togglesAction(std.heap.page_allocator)) return error.PuzzleInputFailed;
}

test "external puzzle reads action-mapped input" {
    try std.testing.expect(try togglesAction(std.testing.allocator));
}
