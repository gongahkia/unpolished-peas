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
    spawned: bool = false,

    pub fn init(ctx: *sdl.Context) !Game {
        return .{ .blip = try ctx.loadSound("blip.wav") };
    }

    pub fn update(self: *Game, ctx: *sdl.Context) !void {
        if (!self.spawned) {
            var i: usize = 0;
            while (i < 96) : (i += 1) {
                _ = try ctx.audio.playSound(try ctx.assets.trySoundPtr(self.blip), .{ .volume = 0.02, .loop = true });
            }
            self.spawned = true;
        }
    }

    pub fn draw(_: *Game, ctx: *sdl.Context) void {
        ctx.text("AUDIO STRESS", 2, 2, up.core.Color.white);
    }
};

pub fn main() !void {
    try sdl.playGame(Game);
}
