const std = @import("std");
const up = @import("unpolished-peas");

/// Compiled for the freestanding browser target to keep the public software
/// surface path exercised across the package boundary without a browser GPU.
pub export fn renderSurfaceWasmSmoke() u32 {
    var surface = up.graphics.RenderSurface.init(std.heap.wasm_allocator, 2, 1) catch return 0;
    defer surface.deinit();
    surface.canvas().clear(up.core.Color.rgb(255, 0, 0));

    var canvas = up.graphics.Canvas.init(std.heap.wasm_allocator, 4, 1) catch return 0;
    defer canvas.deinit();
    canvas.clear(up.core.Color.black);
    canvas.drawSurface(&surface, .{ .x = 0, .y = 0, .width = 4, .height = 1 }) catch return 0;
    const pixel = canvas.get(3, 0) orelse return 0;
    return (@as(u32, pixel.r) << 24) | (@as(u32, pixel.g) << 16) | (@as(u32, pixel.b) << 8) | pixel.a;
}
