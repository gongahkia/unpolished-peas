const std = @import("std");
const up = @import("unpolished-peas");

test "public render surface API composes an owned offscreen Canvas" {
    var surface = try up.graphics.RenderSurface.init(std.testing.allocator, 2, 2);
    defer surface.deinit();
    surface.canvas().clear(up.core.Color.rgb(255, 198, 74));

    var canvas = try up.graphics.Canvas.init(std.testing.allocator, 4, 4);
    defer canvas.deinit();
    canvas.clear(up.core.Color.black);
    try canvas.drawSurface(&surface, .{ .x = 0, .y = 0, .width = 4, .height = 4, .filter = .nearest });
    try std.testing.expectEqual(up.core.Color.rgb(255, 198, 74), canvas.get(3, 3).?);
}
