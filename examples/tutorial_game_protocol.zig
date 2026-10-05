const up = @import("unpolished-peas");
const sdl = @import("unpolished-peas-sdl3");

/// This deliberately small program is the compiled source shown in the
/// Start Here guide. Seed Sprint is the next step when a game needs actions,
/// deterministic RNG, saves, audio, and tests.
const Game = struct {
    pub const config: sdl.Config = .{
        .title = "Peas first game",
        .width = 160,
        .height = 90,
        .scale = 5,
        .clear_color = up.core.Color.rgb(14, 18, 24),
    };

    player_x: f32 = 76,

    pub fn init(_: *Game, _: *up.core.GameContext) !void {}

    pub fn update(self: *Game, ctx: *up.core.GameContext, elapsed_seconds: f32) !void {
        if (ctx.input.isDown(.left)) self.player_x -= 48 * elapsed_seconds;
        if (ctx.input.isDown(.right)) self.player_x += 48 * elapsed_seconds;
    }

    pub fn draw(self: *Game, ctx: *up.core.GameContext) !void {
        const canvas = try ctx.requireCanvas();
        canvas.clear(up.core.Color.rgb(14, 18, 24));
        canvas.fillRect(@intFromFloat(self.player_x), 42, 8, 8, up.core.Color.rgb(255, 198, 74));
        canvas.drawText("LEFT / RIGHT", 48, 12, up.core.Color.white);
    }
};

pub fn main() !void {
    try sdl.playGame(Game);
}
