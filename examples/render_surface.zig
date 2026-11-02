const std = @import("std");
const up = @import("unpolished-peas");

/// A deliberately small pixel-art composition example. The offscreen surface
/// is created once, reused for the scene, and then nearest-scaled to the
/// presentation Canvas. No GPU resource is visible to game code.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var world = try up.graphics.RenderSurface.init(allocator, 40, 24);
    defer world.deinit();
    var screen = try up.graphics.Canvas.init(allocator, 160, 96);
    defer screen.deinit();

    const world_canvas = world.canvas();
    world_canvas.clear(up.core.Color.rgb(16, 22, 36));
    world_canvas.fillRect(2, 2, 36, 20, up.core.Color.rgb(30, 48, 74));
    world_canvas.fillRect(15, 8, 10, 8, up.core.Color.rgb(255, 198, 74));
    world_canvas.drawText("SURFACE", 2, 2, up.core.Color.white);

    screen.clear(up.core.Color.black);
    try screen.drawSurface(&world, .{ .x = 0, .y = 0, .width = 160, .height = 96, .filter = .nearest });
    try std.fs.cwd().makePath("zig-out");
    try screen.writePpmFile("zig-out/render-surface.ppm");
}

test "render surface example uses nearest-scaled composition" {
    var surface = try up.graphics.RenderSurface.init(std.testing.allocator, 1, 1);
    defer surface.deinit();
    surface.canvas().clear(up.core.Color.rgb(255, 198, 74));
    var screen = try up.graphics.Canvas.init(std.testing.allocator, 2, 2);
    defer screen.deinit();
    try screen.drawSurface(&surface, .{ .x = 0, .y = 0, .width = 2, .height = 2 });
    try std.testing.expectEqual(up.core.Color.rgb(255, 198, 74), screen.get(1, 1).?);
}
