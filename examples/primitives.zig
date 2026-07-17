const up = @import("unpolished-peas");
const sdl = @import("unpolished-peas-sdl3");

const Game = struct {
    pub const config: sdl.Config = .{
        .title = "unpolished-peas primitives",
        .width = 128,
        .height = 104,
        .scale = 5,
        .clear_color = up.Color.rgb(14, 18, 24),
    };

    pub fn init(ctx: *sdl.Context) !Game {
        return .{};
    }

    pub fn draw(_: *Game, ctx: *sdl.Context) void {
        ctx.rect(8, 8, 24, 16, up.Color.rgba(255, 198, 74, 220));
        ctx.strokeRect(40, 8, 24, 16, up.Color.rgb(113, 232, 162));
        ctx.circle(20, 48, 10, up.Color.rgba(91, 166, 210, 200));
        ctx.strokeCircle(52, 48, 10, up.Color.rgb(255, 112, 112));
        ctx.pushClip(.{ .x = 64, .y = 8, .w = 32, .h = 20 });
        ctx.rect(64, 8, 48, 20, up.Color.rgba(91, 166, 210, 160));
        ctx.pushClip(.{ .x = 72, .y = 12, .w = 16, .h = 12 });
        ctx.pushBlend(.additive);
        ctx.circle(80, 18, 12, up.Color.rgba(255, 112, 112, 160));
        ctx.popBlend();
        ctx.popClip();
        ctx.popClip();
        ctx.line(72, 38, 104, 58, up.Color.white);
        ctx.triangle(.{ .x = 76, .y = 72 }, .{ .x = 92, .y = 62 }, .{ .x = 108, .y = 72 }, up.Color.rgb(178, 132, 255));
        ctx.strokeTriangle(.{ .x = 76, .y = 86 }, .{ .x = 92, .y = 76 }, .{ .x = 108, .y = 86 }, up.Color.rgb(255, 198, 74));
        ctx.text("GPU PRIMITIVES", 8, 88, up.Color.white);
    }
};

pub fn main() !void {
    try sdl.playGame(Game);
}
