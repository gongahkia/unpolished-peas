const up = @import("unpolished-peas").api;
const sdl = @import("unpolished-peas-sdl3");

const Game = struct {
    pub fn draw(_: *Game, ctx: *sdl.Context) void {
        ctx.rect(18, 18, 28, 28, up.Color.rgb(255, 198, 74));
        ctx.text("HELLO", 8, 8, up.Color.white);
    }
};

pub fn main() !void {
    try sdl.play(.{
        .title = "unpolished-peas minimal",
        .width = 80,
        .height = 60,
        .scale = 6,
        .clear_color = up.Color.rgb(14, 18, 24),
    }, Game);
}
