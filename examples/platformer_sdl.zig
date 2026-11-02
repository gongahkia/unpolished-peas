const up = @import("unpolished-peas");
const sdl = @import("unpolished-peas-sdl3");
const game_mod = @import("platformer_game.zig");

const Game = struct {
    pub const config: sdl.Config = .{ .title = "unpolished-peas Platformer", .width = game_mod.width, .height = game_mod.height, .scale = 5, .fixed_hz = 60, .clear_color = up.core.Color.rgb(15, 23, 38) };

    game: game_mod.Game = .{},
    player: up.assets.ImageHandle,
    blip: up.assets.AudioHandle,

    pub fn init(ctx: *sdl.Context) !Game {
        return .{ .player = try ctx.loadImage("ball.png"), .blip = try ctx.loadSound("blip.wav") };
    }

    pub fn update(self: *Game, ctx: *sdl.Context) !void {
        const event = self.game.step(ctx.input.*, ctx.dt);
        if (event.jumped or event.landed) _ = try ctx.audio.playSound(try ctx.assets.trySoundPtr(self.blip), .{ .volume = if (event.jumped) 0.3 else 0.15 });
    }

    pub fn draw(self: *Game, ctx: *sdl.Context) !void {
        drawWorld(ctx.canvas, self.game);
        try ctx.image(self.player, @intFromFloat(self.game.player.x - 3), @intFromFloat(self.game.player.y - 1));
        ctx.text("PLATFORMER", 4, 4, up.core.Color.white);
        ctx.text("ARROWS SPACE", 78, 4, up.core.Color.rgb(180, 205, 230));
        ctx.text(if (self.game.reached_goal) "GOAL" else "REACH THE FLAG", 4, 86, if (self.game.reached_goal) up.core.Color.rgb(113, 232, 162) else up.core.Color.rgb(255, 198, 74));
    }
};

fn drawWorld(canvas: *up.graphics.Canvas, game: game_mod.Game) void {
    for (game_mod.platforms) |platform| {
        canvas.fillRect(@intFromFloat(platform.x), @intFromFloat(platform.y), @intFromFloat(platform.w), @intFromFloat(platform.h), up.core.Color.rgb(55, 100, 130));
        canvas.strokeRect(@intFromFloat(platform.x), @intFromFloat(platform.y), @intFromFloat(platform.w), @intFromFloat(platform.h), up.core.Color.rgb(113, 232, 162));
    }
    canvas.fillRect(149, 54, 2, 30, up.core.Color.rgb(225, 232, 240));
    canvas.fillRect(151, 54, 7, 6, up.core.Color.rgb(255, 198, 74));
    canvas.strokeRect(@intFromFloat(game.player.x), @intFromFloat(game.player.y), game_mod.player_width, game_mod.player_height, up.core.Color.rgb(255, 198, 74));
}

pub fn main() !void {
    try sdl.playGame(Game);
}
