const std = @import("std");
const up = @import("unpolished-peas");

const State = struct {
    x: i32 = 18,
    velocity: i32 = 1,

    fn event(self: *State, input: up.input.Input) void {
        if (input.wasPressed(.left)) self.velocity = -1;
        if (input.wasPressed(.right)) self.velocity = 1;
    }

    fn update(self: *State) void {
        self.x += self.velocity;
        if (self.x < 0 or self.x > 52) self.velocity = -self.velocity;
    }

    fn draw(self: State, canvas: *up.graphics.Canvas) void {
        canvas.clear(up.core.Color.rgb(14, 18, 24));
        canvas.fillRect(self.x, 18, 28, 28, up.core.Color.rgb(255, 198, 74));
    }
};

pub fn run() !up.core.Color {
    var pixels: [80 * 60]up.core.Color = undefined;
    var canvas = up.graphics.Canvas{ .allocator = std.heap.page_allocator, .width = 80, .height = 60, .pixels = pixels[0..] };
    var state = State{};
    var input = up.input.Input{};
    var frame: u8 = 0;
    while (frame < 3) : (frame += 1) {
        input.beginFrame();
        if (frame == 0) input.set(.right, true);
        state.event(input);
        state.update();
        state.draw(&canvas);
    }
    return canvas.get(state.x, 18) orelse error.MissingDrawnPixel;
}

pub fn main() !void {
    if ((try run()).a == 0) return error.ExplicitLoopDidNotDraw;
}

pub export fn explicit_loop_probe() u32 {
    const color = run() catch return 0;
    return (@as(u32, color.r) << 24) | (@as(u32, color.g) << 16) | (@as(u32, color.b) << 8) | color.a;
}

test "explicit loop owns event update draw ordering" {
    try std.testing.expectEqual(up.core.Color.rgb(255, 198, 74), try run());
}
