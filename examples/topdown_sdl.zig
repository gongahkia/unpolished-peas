const up = @import("unpolished-peas");
const sdl = @import("unpolished-peas-sdl3");
const game_mod = @import("topdown_game.zig");

const Game = struct {
    pub const config: sdl.Config = .{ .title = "unpolished-peas Top Down", .width = game_mod.width, .height = game_mod.height, .scale = 5, .fixed_hz = 60, .clear_color = up.Color.rgb(10, 18, 26) };

    game: game_mod.Game = .{},
    player: up.ImageHandle,
    blip: up.AudioHandle,

    pub fn init(ctx: *sdl.Context) !Game {
        const player = try ctx.loadImage("ball.png");
        const blip = try ctx.loadSound("blip.wav");
        return .{ .player = player, .blip = blip };
    }
    pub fn update(self: *Game, ctx: *sdl.Context) !void {
        const event = self.game.step(ctx.input.*, ctx.dt);
        if (event.fired) _ = try ctx.audio.playSound(try ctx.assets.trySoundPtr(self.blip), .{ .volume = 0.3 });
    }
    pub fn draw(self: *Game, ctx: *sdl.Context) !void {
        ctx.strokeRect(8, 18, 144, 70, up.Color.rgb(91, 166, 210));
        ctx.circle(32, 42, 6, up.Color.rgb(255, 198, 74));
        ctx.circle(128, 62, 6, up.Color.rgb(113, 232, 162));
        try ctx.image(self.player, @intFromFloat(self.game.player.x - 8), @intFromFloat(self.game.player.y - 8));
        ctx.text("TOPDOWN", 4, 4, up.Color.white);
        ctx.text("ARROWS SPACE", 84, 4, up.Color.rgb(180, 205, 230));
    }
};

pub fn main() !void {
    try sdl.playGame(Game);
}
