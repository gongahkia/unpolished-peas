const std = @import("std");
const up = @import("unpolished-peas");

fn landsOnFloor(allocator: std.mem.Allocator) !bool {
    var collider = up.TileCollider.init(allocator);
    defer collider.deinit();
    try collider.addShape(.{ .solid = up.Rect.init(0, 20, 32, 4) });
    var controller = try up.CharacterController.init(.{ .bounds = up.Rect.init(8, 0, 8, 8) });
    return controller.move(&collider, .{ .x = 0, .y = 32 }).grounded;
}

pub fn main() !void {
    if (!try landsOnFloor(std.heap.page_allocator)) return error.PlatformerCollisionFailed;
}

test "external platformer game lands on a tile collider" {
    try std.testing.expect(try landsOnFloor(std.testing.allocator));
}
