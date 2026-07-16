const up = @import("unpolished-peas").api;
const sdl = @import("unpolished-peas-sdl3");
const game_mod = @import("topdown_game.zig");

const Game = struct {
    pub const config: sdl.Config = .{ .title = "unpolished-peas Top Down", .width = game_mod.width, .height = game_mod.height, .scale = 5, .fixed_hz = 60, .clear_color = up.Color.rgb(10, 18, 26) };

    game: game_mod.Game = .{},
    map: up.TileMapHandle,
    player: up.ImageHandle,
    blip: up.AudioHandle,
    camera: up.Camera2D = .{ .position = .{ .x = 80, .y = 48 } },
    pub fn init(ctx: *sdl.Context) !Game {
        return .{ .map = try ctx.loadTileMap("topdown.upmap", .{}), .player = try ctx.loadImage("ball.png"), .blip = try ctx.loadSound("blip.wav") };
    }
    pub fn update(self: *Game, ctx: *sdl.Context) !void {
        const event = self.game.step(ctx.input.*, ctx.dt);
        self.camera.position = self.game.player;
        if (event.fired) _ = try ctx.audio.playSound(try ctx.assets.trySoundPtr(self.blip), .{ .volume = 0.3 });
    }
    pub fn draw(self: *Game, ctx: *sdl.Context) !void {
        try ctx.drawTileMap(self.map, &self.camera, 0);
        try ctx.image(self.player, @intFromFloat(self.game.player.x - 8), @intFromFloat(self.game.player.y - 8));
        ctx.text("TOPDOWN", 4, 4, up.Color.white);
        ctx.text("ARROWS SPACE", 84, 4, up.Color.rgb(180, 205, 230));
    }
};

pub fn main() !void {
    try sdl.playGame(Game);
}
