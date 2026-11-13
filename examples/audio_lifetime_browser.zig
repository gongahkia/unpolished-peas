//! Test observations around the unchanged portable example and normal host.
const up = @import("unpolished-peas");
const demo = @import("audio_lifetime_game.zig");
var current: ?*Game = null;
var audio: ?*up.core.Audio = null;
var cleanup_complete = false;
pub const Game = struct {
    state: demo.Game = .{},
    pub fn init(self: *Game, ctx: *up.core.GameContext) !void {
        current = null;
        audio = null;
        cleanup_complete = false;
        try self.state.init(ctx);
        current = self;
        audio = ctx.audio;
    }
    pub fn update(self: *Game, ctx: *up.core.GameContext, dt: f32) !void {
        try self.state.update(ctx, dt);
    }
    pub fn draw(self: *Game, ctx: *up.core.GameContext) !void {
        try self.state.draw(ctx);
    }
    pub fn deinit(self: *Game, ctx: *up.core.GameContext) !void {
        try self.state.deinit(ctx);
        cleanup_complete = !(try ctx.requireAudio()).hasActivePlayback();
        current = null;
        audio = null;
    }
};
pub export fn audio_lifetime_metric(field: u32) u32 {
    if (field == 8) return @intFromBool(cleanup_complete);
    const game = current orelse return 0;
    const host = audio orelse return 0;
    return switch (field) {
        0 => game.state.transitions,
        1 => game.state.scene,
        2 => @intCast(host.sounds.items.len),
        3 => @intCast(host.music_sources.items.len),
        4 => @intFromEnum(host.musicState()),
        5 => @intFromBool(game.state.playback_ready),
        6 => countSounds(host),
        7 => countMusic(host),
        else => 0,
    };
}
fn countSounds(host: *const up.core.Audio) u32 {
    var count: u32 = 0;
    for (host.sounds.items) |slot| if (slot.generation != 0) {
        count += 1;
    };
    return count;
}
fn countMusic(host: *const up.core.Audio) u32 {
    var count: u32 = 0;
    for (host.music_sources.items) |slot| if (slot.generation != 0) {
        count += 1;
    };
    return count;
}
