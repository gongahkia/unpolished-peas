//! Optional verification host. Production main.zig never imports this module.
//! Replays ordinary fixed-tick input through the real SDL GameProtocol host.
const std = @import("std");
const up = @import("unpolished-peas");
const sdl = @import("unpolished-peas-sdl3");
const game = @import("game.zig");
const save = @import("save.zig");
const options = @import("verification-options");
var passed = false;
var cleaned = false;
const Desktop = struct {
    pub const config: sdl.Config = .{
        .title = "Ashen Causeway - native verification",
        .organization = "peas-ashen-verification",
        .application = options.application,
        .width = game.width,
        .height = game.height,
        .scale = 2,
        .simulation_seed = game.default_seed,
        .pause_policy = .never,
        .developer_tools = true,
        .cpu_profiler = false,
        .max_frames = 7200,
    };
    state: game.Game = .{},
    replay: ?up.preview.developer.InputReplay = null,
    output: ?[]u8 = null,
    continuing: bool = false,
    tick: usize = 0,
    captured: [5]bool = .{false} ** 5,
    pub fn init(d: *Desktop, ctx: *up.core.GameContext) !void {
        const allocator = try ctx.requireAllocator();
        errdefer d.deinit(ctx) catch {};
        const mode = try std.process.getEnvVarOwned(allocator, "ASHEN_VERIFY_MODE");
        defer allocator.free(mode);
        d.continuing = std.mem.eql(u8, mode, "continue");
        if (!d.continuing and !std.mem.eql(u8, mode, "route")) return error.InvalidVerificationMode;
        d.output = try std.process.getEnvVarOwned(allocator, "ASHEN_VERIFY_OUTPUT");
        try std.fs.cwd().makePath(d.output.?);
        try d.state.init(ctx);
        if (d.continuing) {
            if (!d.state.journey_started or !d.state.state.completed or !d.state.state.boss_defeated) return error.CompletedJourneyNotReloaded;
            if (d.state.state.checkpoint != 2 or d.state.state.upgrade != 1 or d.state.state.player.weapon != .spear) return error.ProgressionNotReloaded;
            if (d.state.state.player.hp != d.state.state.player.max_hp or d.state.state.player.flasks != 4) return error.TransientStateNotReset;
        } else {
            if (d.state.journey_started) return error.VerificationNamespaceNotEmpty;
            const path = try std.process.getEnvVarOwned(allocator, "ASHEN_VERIFY_REPLAY");
            defer allocator.free(path);
            const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
            defer allocator.free(bytes);
            d.replay = try up.preview.developer.parseInputReplay(allocator, bytes);
            if (d.replay.?.fixed_hz != 60 or d.replay.?.simulation_seed != game.default_seed) return error.ReplayEnvironmentMismatch;
        }
    }
    pub fn update(d: *Desktop, ctx: *up.core.GameContext, dt: f32) !void {
        if (passed) return;
        var input = up.input.Input{};
        if (d.continuing) {
            input.set(.start, d.tick == 0);
        } else {
            if (d.tick >= d.replay.?.frames.len) return error.ReplayEndedWithoutVictory;
            try d.replay.?.applyFrame(d.tick, &input);
        }
        var borrowed = ctx.*;
        borrowed.input = &input;
        try d.state.update(&borrowed, dt);
        d.tick += 1;
        if (d.tick % 600 == 0) std.debug.print("ashen native progress: ticks={d} room={d} hp={d}\n", .{ d.tick, d.state.state.room, d.state.state.player.hp });
        if (d.continuing or d.tick == d.replay.?.frames.len) {
            if (!d.state.state.completed or d.state.save_failed) return error.EndingNotSaved;
            var bytes: [save.size]u8 = undefined;
            const persisted = try save.decode(try (try ctx.requireSaveData()).read(save.key, &bytes));
            if (!persisted.state.completed or !persisted.state.boss_defeated) return error.EndingNotPersisted;
            passed = true;
            std.debug.print("ashen native passed: mode={s} ticks={d} checkpoint={d} upgrade={d} hp={d}\n", .{ if (d.continuing) "continue" else "route", d.tick, d.state.state.checkpoint, d.state.state.upgrade, d.state.state.player.hp });
        }
    }
    fn capture(d: *Desktop, ctx: *up.core.GameContext, label: []const u8) !void {
        var path: [1024]u8 = undefined;
        try (try ctx.requireCanvas()).writePngFile(try std.fmt.bufPrint(&path, "{s}/{s}.png", .{ d.output.?, label }));
    }
    pub fn draw(d: *Desktop, ctx: *up.core.GameContext) !void {
        try d.state.draw(ctx);
        if (d.state.state.room == 1 and !d.captured[0]) {
            try d.capture(ctx, "cloister");
            d.captured[0] = true;
        }
        for (d.state.state.enemies) |e| if (e.kind == .warden and e.hp > 0) {
            if (e.stage == .windup and !d.captured[1]) {
                try d.capture(ctx, "warden-windup");
                d.captured[1] = true;
            }
            if (e.stage == .transition and !d.captured[2]) {
                try d.capture(ctx, "warden-transition");
                d.captured[2] = true;
            }
        };
        for (d.state.state.rings) |r| if (r.alive and r.age > 10 and !d.captured[3]) {
            try d.capture(ctx, "warden-shock");
            d.captured[3] = true;
        };
        if (passed and !d.captured[4]) {
            try d.capture(ctx, if (d.continuing) "continued" else "victory");
            d.captured[4] = true;
        }
    }
    pub fn deinit(d: *Desktop, ctx: *up.core.GameContext) !void {
        const allocator = try ctx.requireAllocator();
        try d.state.deinit(ctx);
        if (d.replay) |*r| r.deinit(allocator);
        d.replay = null;
        if (d.output) |p| allocator.free(p);
        d.output = null;
        if ((try ctx.requireAudio()).hasActivePlayback()) return error.PlaybackSurvivedCleanup;
        cleaned = true;
    }
};
pub fn main() !void {
    try sdl.playGame(Desktop);
    if (!passed or !cleaned) return error.IncompleteNativeVerification;
    std.debug.print("ashen native cleanup verified\n", .{});
}
