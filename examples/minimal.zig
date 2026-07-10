const std = @import("std");
const up = @import("unpolished");
const sdl = @import("unpolished_sdl3");

const Game = struct {
    pub fn init(_: std.mem.Allocator) !Game {
        return .{};
    }

    pub fn deinit(_: *Game) void {}

    pub fn update(_: *Game, _: sdl.Frame) !void {}

    pub fn render(_: *Game, frame: sdl.Frame) !void {
        frame.canvas.fillRect(18, 18, 28, 28, up.Color.rgb(255, 198, 74));
        frame.canvas.drawText("HELLO", 8, 8, up.Color.white);
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    try sdl.run(gpa.allocator(), .{
        .title = "minimal",
        .width = 80,
        .height = 60,
        .scale = 6,
        .clear_color = up.Color.rgb(14, 18, 24),
    }, Game);
}
