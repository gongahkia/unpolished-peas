const std = @import("std");
const up = @import("unpolished-peas").api;

fn movesRight(allocator: std.mem.Allocator) !bool {
    const definitions = [_]up.Action{
        .{ .name = "move_right", .binding = .{ .key = .right } },
    };
    var actions = try up.ActionMap.init(allocator, &definitions);
    defer actions.deinit();
    var input = up.Input{};
    input.set(.right, true);
    actions.update(input);
    return actions.isDown("game", "move_right") and actions.value(input, "game", "move_right") == 1;
}

pub fn main() !void {
    if (!try movesRight(std.heap.page_allocator)) return error.TopdownInputFailed;
}

test "external top-down game reads action-mapped input" {
    try std.testing.expect(try movesRight(std.testing.allocator));
}
