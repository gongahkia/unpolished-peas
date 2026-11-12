//! Optional real SDL verification host. It never enters normal game bundles.
const std = @import("std");
const up = @import("unpolished-peas");
const sdl = @import("unpolished-peas-sdl3");
const game = @import("game.zig");
const options = @import("verification-options");
var passed = false;
var cleaned = false;
const Desktop = struct {
    pub const config: sdl.Config = .{ .title = "lantern-leap verification", .organization = "peas-reference-verification", .application = options.application, .width = game.width, .height = game.height, .scale = 3, .simulation_seed = game.default_seed, .pause_policy = .never, .developer_tools = false, .cpu_profiler = false, .max_frames = options.frame_limit };
    state: game.Game = .{},
    replay: ?up.preview.developer.InputReplay = null,
    tick: usize = 0,
    limit: usize = 0,
    start: usize = 0,
    reload: bool = false,
    profiling: bool = false,
    output: ?[]u8 = null,
    captured: bool = false,
    pub fn init(d: *Desktop, ctx: *up.core.GameContext) !void {
        const a = try ctx.requireAllocator();
        errdefer d.deinit(ctx) catch {};
        const mode = try std.process.getEnvVarOwned(a, "REFERENCE_VERIFY_MODE");
        defer a.free(mode);
        d.reload = std.mem.eql(u8, mode, "reload");
        d.profiling = std.mem.eql(u8, mode, "profile");
        if (!d.reload and !d.profiling and !std.mem.eql(u8, mode, "route")) return error.InvalidMode;
        d.output = try std.process.getEnvVarOwned(a, "REFERENCE_VERIFY_OUTPUT");
        try std.fs.cwd().makePath(d.output.?);
        try d.state.init(ctx);
        if (d.reload) {
            var bytes: [16]u8 = undefined;
            const actual = try (try ctx.requireSaveData()).read("progress.v2", &bytes);
            const path = try std.process.getEnvVarOwned(a, "REFERENCE_EXPECTED_SAVE");
            defer a.free(path);
            const expected = try std.fs.cwd().readFileAlloc(a, path, 16);
            defer a.free(expected);
            if (!std.mem.eql(u8, actual, expected)) return error.ReloadMismatch;
            const saved = try @import("progress.zig").decode(actual);
            if (d.state.best_collectibles != saved.best or d.state.checkpoint != saved.checkpoint or d.state.record().mask != saved.mask or d.state.audio_enabled != saved.audio) return error.LoadedStateMismatch;
        } else {
            const path = try std.process.getEnvVarOwned(a, "REFERENCE_VERIFY_REPLAY");
            defer a.free(path);
            const bytes = try std.fs.cwd().readFileAlloc(a, path, 16 * 1024 * 1024);
            defer a.free(bytes);
            d.replay = try up.preview.developer.parseInputReplay(a, bytes);
            if (d.replay.?.fixed_hz != 60 or d.replay.?.simulation_seed != game.default_seed) return error.EnvironmentMismatch;
            d.limit = d.replay.?.frames.len;
            if (std.process.getEnvVarOwned(a, "REFERENCE_VERIFY_LIMIT")) |v| {
                defer a.free(v);
                d.limit = try std.fmt.parseInt(usize, v, 10);
            } else |_| {}
            if (d.limit > d.replay.?.frames.len) return error.BadLimit;
            if (d.profiling) {
                const v = try std.process.getEnvVarOwned(a, "REFERENCE_PROFILE_SKIP");
                defer a.free(v);
                d.start = try std.fmt.parseInt(usize, v, 10);
                if (d.start >= d.limit) return error.BadProfileStart;
                var pcm: [800]up.assets.AudioSample = undefined;
                for (0..d.start) |i| {
                    var input = up.input.Input{};
                    try d.replay.?.applyFrame(i, &input);
                    var borrowed = ctx.*;
                    borrowed.input = &input;
                    borrowed.elapsed_seconds = 1.0 / 60.0;
                    try d.state.update(&borrowed, 1.0 / 60.0);
                    try (try ctx.requireAudio()).mix(&pcm);
                }
                d.tick = d.start;
            }
        }
    }
    pub fn update(d: *Desktop, ctx: *up.core.GameContext, dt: f32) !void {
        if (passed and !d.profiling) return;
        var input = up.input.Input{};
        if (!d.reload and d.tick < d.limit) try d.replay.?.applyFrame(d.tick, &input);
        var borrowed = ctx.*;
        borrowed.input = &input;
        try d.state.update(&borrowed, dt);
        d.tick += 1;
        if (d.state.save_failed) return error.PersistenceFailed;
        if (!d.profiling and (d.reload or d.tick == d.limit)) passed = true;
    }
    pub fn draw(d: *Desktop, ctx: *up.core.GameContext) !void {
        try d.state.draw(ctx);
        // Bound ordinary route duration independently of swapchain cadence.
        // This pacing is disabled for all native performance observations.
        if (!d.profiling) std.Thread.sleep(17 * std.time.ns_per_ms);
        if (!d.profiling and passed and !d.captured) {
            const a = try ctx.requireAllocator();
            const path = try std.fs.path.join(a, &.{ d.output.?, "final.png" });
            defer a.free(path);
            try (try ctx.requireCanvas()).writePngFile(path);
            d.captured = true;
        }
    }
    pub fn deinit(d: *Desktop, ctx: *up.core.GameContext) !void {
        const a = try ctx.requireAllocator();
        if (d.profiling) passed = d.tick > d.start;
        if (!passed) std.debug.print("reference native incomplete: tick={d} limit={d} start={d}\n", .{ d.tick, d.limit, d.start });
        if (passed) {
            var bytes: [16]u8 = undefined;
            const actual = try (try ctx.requireSaveData()).read("progress.v2", &bytes);
            const path = try std.fs.path.join(a, &.{ d.output.?, "saved.bin" });
            defer a.free(path);
            try std.fs.cwd().writeFile(.{ .sub_path = path, .data = actual });
            std.debug.print("reference native lantern-leap: ticks={d} start={d} reload={} profile={} saved={x}\n", .{ d.tick, d.start, d.reload, d.profiling, actual });
        }
        try d.state.deinit(ctx);
        if (d.replay) |*r| r.deinit(a);
        d.replay = null;
        if (d.output) |p| a.free(p);
        d.output = null;
        if ((try ctx.requireAudio()).hasActivePlayback()) return error.PlaybackSurvivedCleanup;
        cleaned = true;
    }
};
pub fn main() !void {
    try sdl.playGame(Desktop);
    if (!passed or !cleaned) return error.IncompleteVerification;
    std.debug.print("reference native lantern-leap cleanup passed\n", .{});
}
