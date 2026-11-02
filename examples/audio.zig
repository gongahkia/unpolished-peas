const up = @import("unpolished-peas");
const sdl = @import("unpolished-peas-sdl3");

const Game = struct {
    pub const config: sdl.Config = .{
        .title = "unpolished-peas audio",
        .width = 128,
        .height = 72,
        .scale = 5,
        .clear_color = up.core.Color.rgb(14, 18, 24),
    };

    blip: up.assets.AudioHandle,

    pub fn init(ctx: *sdl.Context) !Game {
        return .{ .blip = try ctx.loadSound("blip.wav") };
    }

    pub fn update(self: *Game, ctx: *sdl.Context) !void {
        if (ctx.input.wasPressed(.action)) {
            _ = try ctx.audio.playSound(try ctx.assets.trySoundPtr(self.blip), .{ .volume = 0.8 });
        }
    }

    pub fn draw(_: *Game, ctx: *sdl.Context) void {
        ctx.text("AUDIO", 8, 8, up.core.Color.white);
        ctx.text("SPACE: SFX", 8, 20, up.core.Color.rgb(113, 232, 162));
        ctx.text("WAV SFX", 8, 32, up.core.Color.rgb(255, 198, 74));
    }
};

pub fn main() !void {
    try sdl.playGame(Game);
}
