const up = @import("unpolished-peas");
const sdl = @import("unpolished-peas-sdl3");

const Game = struct {
    pub const config: sdl.Config = .{
        .title = "unpolished-peas audio",
        .width = 128,
        .height = 72,
        .scale = 5,
        .clear_color = up.Color.rgb(14, 18, 24),
    };

    blip: up.AudioHandle,
    music: up.Music,
    music_handle: ?up.PlaybackHandle = null,

    pub fn init(ctx: *sdl.Context) !Game {
        const music_path = try ctx.assetPath("tone.ogg");
        defer ctx.allocator.free(music_path);
        var game = Game{
            .blip = try ctx.loadSound("blip.wav"),
            .music = try up.Music.openOgg(ctx.allocator, music_path),
        };
        errdefer game.music.deinit();
        game.music_handle = try ctx.audio.playMusic(&game.music, .{ .volume = 0.25, .loop = true });
        return game;
    }

    pub fn deinit(self: *Game, ctx: *sdl.Context) void {
        if (self.music_handle) |handle| _ = ctx.audio.stop(handle);
        self.music.deinit();
    }

    pub fn update(self: *Game, ctx: *sdl.Context) !void {
        if (ctx.input.wasPressed(.action)) {
            _ = try ctx.audio.playSound(try ctx.assets.trySoundPtr(self.blip), .{ .volume = 0.8 });
        }
    }

    pub fn draw(_: *Game, ctx: *sdl.Context) void {
        ctx.text("AUDIO", 8, 8, up.Color.white);
        ctx.text("SPACE: SFX", 8, 20, up.Color.rgb(113, 232, 162));
        ctx.text("MUSIC: OGG LOOP", 8, 32, up.Color.rgb(255, 198, 74));
    }
};

pub fn main() !void {
    try sdl.playGame(Game);
}
