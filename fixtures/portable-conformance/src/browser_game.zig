//! Fixture-owned observation exports. Game logic uses only portable public
//! APIs; these exports let browser tests inspect it without private engine hooks.
const up = @import("unpolished-peas");
const game = @import("game.zig");
pub const storage_id = game.storage_id;
var active: ?*game.Game = null;
var reject_next = false;
var cleanups: u32 = 0;
var snapshot: [game.progress_size]u8 = undefined;

pub const Game = struct {
    state: game.Game = .{},
    pub fn init(self: *Game, ctx: *up.core.GameContext) !void {
        self.state.reject_init = reject_next;
        reject_next = false;
        self.state.init(ctx) catch |err| {
            cleanups += self.state.cleanup_calls;
            active = null;
            return err;
        };
        active = &self.state;
    }
    pub fn update(self: *Game, ctx: *up.core.GameContext, dt: f32) !void {
        try self.state.update(ctx, dt);
    }
    pub fn draw(self: *Game, ctx: *up.core.GameContext) !void {
        try self.state.draw(ctx);
    }
    pub fn deinit(self: *Game, ctx: *up.core.GameContext) !void {
        // The protocol promises host capabilities remain alive during cleanup.
        (try ctx.requireCanvas()).fillRect(0, 0, 1, 1, up.core.Color.white);
        _ = try (try ctx.requireAudio()).loadWav(@embedFile("assets/blip.wav"));
        try self.state.deinit(ctx);
        cleanups += self.state.cleanup_calls;
        active = null;
    }
};
pub export fn conformance_reject_next_init() void {
    reject_next = true;
}
pub export fn conformance_cleanups() u32 {
    return cleanups;
}
pub export fn conformance_snapshot() u32 {
    const state = active orelse return 0;
    snapshot = state.progress();
    return @intCast(@intFromPtr(&snapshot));
}
pub export fn conformance_metric(index: u32) u32 {
    const state = active orelse return 0;
    return switch (index) {
        0 => @intCast(state.x),
        1 => @intCast(state.preedit_len),
        2 => @intFromBool(state.editing),
        3 => state.sound_requests,
        4 => @intCast(state.animation.?.currentFrame().index),
        else => 0,
    };
}
