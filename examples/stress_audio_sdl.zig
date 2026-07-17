const up = @import("unpolished-peas");
const sdl = @import("unpolished-peas-sdl3");

const Game = struct {
    pub const config: sdl.Config = .{
        .title = "unpolished-peas audio stress",
        .width = 80,
        .height = 24,
        .scale = 4,
        .max_frames = 3,
        .audio_buffer_frames = 256,
        .strict_audio = false,
        .clear_color = up.core.Color.rgb(14, 18, 24),
    };

    blip: up.assets.AudioHandle,
    music: up.assets.Music,
    music_handle: ?up.assets.PlaybackHandle = null,
    spawned: bool = false,

    pub fn init(ctx: *sdl.Context) !Game {
        const music_path = try ctx.assetPath("tone.ogg");
        defer ctx.allocator.free(music_path);
        var game = Game{
            .blip = try ctx.loadSound("blip.wav"),
            .music = try up.assets.Music.openOgg(ctx.allocator, music_path),
        };
        errdefer game.music.deinit();
        game.music_handle = try ctx.audio.playMusic(&game.music, .{ .volume = 0.1, .loop = true });
        return game;
    }

    pub fn deinit(self: *Game, ctx: *sdl.Context) void {
        if (self.music_handle) |handle| _ = ctx.audio.stop(handle);
        self.music.deinit();
    }

    pub fn update(self: *Game, ctx: *sdl.Context) !void {
        if (!self.spawned) {
            var i: usize = 0;
            while (i < 96) : (i += 1) {
                _ = try ctx.audio.playSound(try ctx.assets.trySoundPtr(self.blip), .{ .volume = 0.02, .loop = true });
            }
            try ctx.audio.setBusVolume(up.assets.AudioMixer.sfxBus(), 0.5);
            self.spawned = true;
        }
        if ((ctx.frame % 30) == 0) {
            try ctx.audio.setBusVolume(up.assets.AudioMixer.masterBus(), if ((ctx.frame % 60) == 0) 0.6 else 0.3);
        }
    }

    pub fn draw(_: *Game, ctx: *sdl.Context) void {
        ctx.text("AUDIO STRESS", 2, 2, up.core.Color.white);
    }
};

pub fn main() !void {
    try sdl.playGame(Game);
}
