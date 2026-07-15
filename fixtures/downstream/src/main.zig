const std = @import("std");
const up = @import("unpolished-peas").api;
const sdl = @import("unpolished-peas-sdl3");

pub fn main() !void {
    const runtime_config: sdl.Config = .{ .max_frames = 1 };
    _ = runtime_config;

    var canvas = try up.Canvas.init(std.heap.page_allocator, 2, 2);
    defer canvas.deinit();
    canvas.clear(up.Color.black);
    canvas.fillRect(0, 0, 1, 1, up.Color.white);
    if (canvas.pixels[0].r != 255) return error.DrawFailed;
}
