const std = @import("std");
const up = @import("unpolished-peas");

fn rendersBall(allocator: std.mem.Allocator) !bool {
    var canvas = try up.Canvas.init(allocator, 32, 18);
    defer canvas.deinit();
    const ball = up.Vec2.init(14, 8).add(.{ .x = 2, .y = 2 });
    const color = up.Color.rgb(255, 192, 0);
    canvas.clear(up.Color.black);
    canvas.fillCircle(@intFromFloat(ball.x), @intFromFloat(ball.y), 2, color);
    return std.meta.eql(canvas.get(16, 10).?, color);
}

pub fn main() !void {
    if (!try rendersBall(std.heap.page_allocator)) return error.BounceRenderFailed;
}

test "external bounce game renders a ball" {
    try std.testing.expect(try rendersBall(std.testing.allocator));
}
