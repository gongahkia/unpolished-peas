const up = @import("unpolished-peas");
const sdl = @import("unpolished-peas-sdl3");

const Game = struct {
    blip: up.Sound,
    music: up.Music,
    music_handle: ?up.PlaybackHandle = null,
    spawned: bool = false,

    pub fn init(ctx: *sdl.Context) !Game {
        const blip_path = try ctx.assetPath("blip.wav");
        defer ctx.allocator.free(blip_path);
        const music_path = try ctx.assetPath("tone.ogg");
        defer ctx.allocator.free(music_path);
        var game = Game{
            .blip = try up.Sound.loadWav(ctx.allocator, blip_path),
            .music = try up.Music.openOgg(ctx.allocator, music_path),
        };
        errdefer {
            game.music.deinit();
            game.blip.deinit();
        }
        game.music_handle = try ctx.audio.playMusic(&game.music, .{ .volume = 0.1, .loop = true });
        return game;
    }

    pub fn deinit(self: *Game, ctx: *sdl.Context) void {
        if (self.music_handle) |handle| _ = ctx.audio.stop(handle);
        self.music.deinit();
        self.blip.deinit();
    }

    pub fn update(self: *Game, ctx: *sdl.Context) !void {
        if (!self.spawned) {
            var i: usize = 0;
            while (i < 96) : (i += 1) {
                _ = try ctx.audio.playSound(&self.blip, .{ .volume = 0.02, .loop = true });
            }
            try ctx.audio.setBusVolume(up.AudioMixer.sfxBus(), 0.5);
            self.spawned = true;
        }
        if ((ctx.frame % 30) == 0) {
            try ctx.audio.setBusVolume(up.AudioMixer.masterBus(), if ((ctx.frame % 60) == 0) 0.6 else 0.3);
        }
    }

    pub fn draw(_: *Game, ctx: *sdl.Context) void {
        ctx.text("AUDIO STRESS", 2, 2, up.Color.white);
    }
};

pub fn main() !void {
    try sdl.play(.{
        .title = "unpolished-peas audio stress",
        .width = 80,
        .height = 24,
        .scale = 4,
        .max_frames = 3,
        .audio_buffer_frames = 256,
        .strict_audio = false,
        .clear_color = up.Color.rgb(14, 18, 24),
    }, Game);
}
