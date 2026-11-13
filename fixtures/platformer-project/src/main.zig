const std = @import("std");
const up = @import("unpolished-peas");

fn jumpsAction(allocator: std.mem.Allocator) !bool {
    const definitions = [_]up.input.Action{
        .{ .name = "jump", .binding = .{ .key = .action } },
    };
    var actions = try up.input.ActionMap.init(allocator, &definitions);
    defer actions.deinit();
    var input = up.input.Input{};
    input.set(.action, true);
    actions.update(input);
    return actions.isDown("game", "jump") and actions.value(input, "game", "jump") == 1;
}

pub fn main() !void {
    if (!try jumpsAction(std.heap.page_allocator)) return error.PlatformerInputFailed;
}

test "external platformer reads action-mapped input" {
    try std.testing.expect(try jumpsAction(std.testing.allocator));
}
