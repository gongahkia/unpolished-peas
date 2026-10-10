const std = @import("std");
const up = @import("unpolished-peas");
const neon = @import("neon-game");
const lantern = @import("lantern-game");

const scale = 8;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var neon_runner = try up.testSupport.HeadlessGameRunner(neon.Game).initSeeded(allocator, neon.width, neon.height, neon.default_seed);
    defer neon_runner.deinit();
    for (0..100) |frame| {
        const buttons: u8 = if (frame < 30) up.testSupport.Buttons.right | up.testSupport.Buttons.action else up.testSupport.Buttons.action;
        try neon_runner.run(&.{.{ .buttons = buttons }});
    }
    try saveScaled(allocator, neon_runner.canvas, "asset/reference/neon-siege.png");

    var lantern_runner = try up.testSupport.HeadlessGameRunner(lantern.Game).initSeeded(allocator, lantern.width, lantern.height, lantern.default_seed);
    defer lantern_runner.deinit();
    for (0..42) |frame| {
        const buttons: u8 = up.testSupport.Buttons.right | (if (frame == 8) up.testSupport.Buttons.action else @as(u8, 0));
        try lantern_runner.run(&.{.{ .buttons = buttons }});
    }
    try saveScaled(allocator, lantern_runner.canvas, "asset/reference/lantern-leap.png");
}

fn saveScaled(allocator: std.mem.Allocator, source: up.graphics.Canvas, path: []const u8) !void {
    var result = try up.graphics.Canvas.init(allocator, source.width * scale, source.height * scale);
    defer result.deinit();
    for (0..source.height) |y| {
        for (0..source.width) |x| {
            const color = source.get(@intCast(x), @intCast(y)).?;
            result.fillRect(@intCast(x * scale), @intCast(y * scale), scale, scale, color);
        }
    }
    try result.writePngFile(path);
}
