const std = @import("std");
const up = @import("unpolished-peas");
const sdl = @import("unpolished-peas-sdl3");
const demo = @import("audio_lifetime_game.zig");
const options = @import("audio-lifetime-options");
var transitions: u32 = 0;
var cleaned_up = false;
const Desktop = struct {
    pub const config: sdl.Config = .{
        .title = "Peas audio scene lifetimes",
        .organization = "peas-audio-example",
        .application = options.application,
        .width = demo.width,
        .height = demo.height,
        .scale = 3,
    };
    state: demo.Game = .{},
    frames: u32 = 0,
    pub fn init(self: *Desktop, ctx: *up.core.GameContext) !void {
        if (options.smoke and (try ctx.requireAudio()).availability() != .ready) return error.NativeAudioDeviceUnavailable;
        try self.state.init(ctx);
    }
    pub fn update(self: *Desktop, ctx: *up.core.GameContext, dt: f32) !void {
        try self.state.update(ctx, dt);
    }
    pub fn draw(self: *Desktop, ctx: *up.core.GameContext) !void {
        if (options.smoke and self.frames < 8) {
            const old = self.state.scene_sound.?;
            try self.state.changeScene(ctx);
            if ((try ctx.requireAudio()).unloadSound(old)) return error.StaleSceneSoundAccepted;
            transitions += 1;
        }
        self.frames += 1;
        try self.state.draw(ctx);
    }
    pub fn deinit(self: *Desktop, ctx: *up.core.GameContext) !void {
        try self.state.deinit(ctx);
        if (options.smoke and (try ctx.requireAudio()).hasActivePlayback()) return error.ScenePlaybackSurvivedCleanup;
        cleaned_up = true;
    }
};
pub fn main() !void {
    try sdl.playGame(Desktop);
    if (options.smoke) {
        if (transitions != 8 or !cleaned_up) return error.IncompleteAudioLifetimeSmoke;
        std.debug.print("audio-lifetime-native passed: transitions={d} game_cleanup=true\n", .{transitions});
    }
}
