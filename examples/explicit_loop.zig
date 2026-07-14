const up = @import("unpolished-peas");
const sdl = @import("unpolished-peas-sdl3");

const State = struct {
    x: i32 = 18,
    velocity: i32 = 1,

    fn update(self: *State, ctx: *sdl.Context) void {
        if (ctx.down(.left)) self.velocity = -1;
        if (ctx.down(.right)) self.velocity = 1;
        self.x += self.velocity;
        if (self.x < 0 or self.x > 52) self.velocity = -self.velocity;
    }

    fn draw(self: *State, ctx: *sdl.Context) void {
        ctx.rect(self.x, 18, 28, 28, up.Color.rgb(255, 198, 74));
        ctx.text("EXPLICIT", 8, 8, up.Color.white);
    }
};

pub fn main() !void {
    var state = State{};
    try sdl.run(.{
        .title = "unpolished-peas explicit loop",
        .width = 80,
        .height = 60,
        .scale = 6,
        .clear_color = up.Color.rgb(14, 18, 24),
    }, &state, .{
        .update = State.update,
        .draw = State.draw,
    });
}
