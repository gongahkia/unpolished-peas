//! Optional verification host. Production main.zig never imports this module.
//! Replays ordinary fixed-tick input through the real SDL GameProtocol host.
const std = @import("std");
const up = @import("unpolished-peas");
const sdl = @import("unpolished-peas-sdl3");
const game = @import("game.zig");
const save = @import("save.zig");
const options = @import("verification-options");
const observations = @import("profile_saves.zig");
const state_digest = @import("profile_state.zig").digest;
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
    profiling: bool = false,
    capture_saves: ?*observations.Capture = null,
    profile_start: usize = 0,
    tick: usize = 0,
    captured: [5]bool = .{false} ** 5,
    pub fn init(d: *Desktop, ctx: *up.core.GameContext) !void {
        const allocator = try ctx.requireAllocator();
        errdefer d.deinit(ctx) catch {};
        const mode = try std.process.getEnvVarOwned(allocator, "ASHEN_VERIFY_MODE");
        defer allocator.free(mode);
        d.continuing = std.mem.eql(u8, mode, "continue");
        d.profiling = std.mem.eql(u8, mode, "profile");
        if (!d.continuing and !d.profiling and !std.mem.eql(u8, mode, "route")) return error.InvalidVerificationMode;
        d.output = try std.process.getEnvVarOwned(allocator, "ASHEN_VERIFY_OUTPUT");
        try std.fs.cwd().makePath(d.output.?);
        if (d.profiling) {
            const enabled = std.process.getEnvVarOwned(allocator, "ASHEN_PROFILE_SAVES") catch null;
            defer if (enabled) |value| allocator.free(value);
            if (enabled) |value| {
                if (!std.mem.eql(u8, value, "1")) return error.InvalidSaveObservationMode;
                const recording = try allocator.create(observations.Capture);
                recording.init() catch |err| {
                    allocator.destroy(recording);
                    return err;
                };
                d.capture_saves = recording;
            }
        }
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
            if (d.profiling) {
                const skip = try std.process.getEnvVarOwned(allocator, "ASHEN_PROFILE_SKIP");
                defer allocator.free(skip);
                d.profile_start = try std.fmt.parseInt(usize, skip, 10);
                if (d.profile_start + 600 >= d.replay.?.frames.len) return error.ProfileRangeInvalid;
                var pcm: [800]up.assets.AudioSample = undefined;
                for (0..d.profile_start) |index| {
                    var input = up.input.Input{};
                    try d.replay.?.applyFrame(index, &input);
                    var borrowed = ctx.*;
                    borrowed.input = &input;
                    borrowed.elapsed_seconds = 1.0 / 60.0;
                    borrowed.interpolation_alpha = 0;
                    try d.state.update(&borrowed, 1.0 / 60.0);
                    try (try ctx.requireAudio()).mix(&pcm);
                }
                d.tick = d.profile_start;
                std.debug.print("ashen profile start: tick={d} room={d}\n", .{ d.tick, d.state.state.room });
            }
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
        var wrapper: observations.Wrapper = undefined;
        const started = if (d.capture_saves) |recording| recording.collector.beginUpdate(d.tick) else 0;
        defer if (d.capture_saves) |recording| recording.collector.endUpdate(started);
        if (d.capture_saves) |recording| {
            wrapper = .{ .parent = try ctx.requireSaveData(), .collector = &recording.collector };
            borrowed.save_data = wrapper.capability();
        }
        try d.state.update(&borrowed, dt);
        if (d.profiling and d.state.save_failed) return error.ProfilePersistenceFailed;
        d.tick += 1;
        if (!d.profiling and d.tick % 600 == 0) std.debug.print("ashen native progress: ticks={d} room={d} hp={d}\n", .{ d.tick, d.state.state.room, d.state.state.player.hp });
        if (!d.profiling and (d.continuing or d.tick == d.replay.?.frames.len)) {
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
        if (d.profiling) return;
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
        defer if (d.capture_saves) |recording| {
            allocator.destroy(recording);
            d.capture_saves = null;
        };
        var report_failure: ?anyerror = null;
        if (d.profiling) {
            passed = d.tick >= d.profile_start + 240;
            std.debug.print("ashen profile end: tick={d} room={d}\n", .{ d.tick, d.state.state.room });
            d.writeProfile(ctx) catch |err| {
                report_failure = err;
            };
        }
        try d.state.deinit(ctx);
        if (d.replay) |*r| r.deinit(allocator);
        d.replay = null;
        if (d.output) |p| allocator.free(p);
        d.output = null;
        if ((try ctx.requireAudio()).hasActivePlayback()) return error.PlaybackSurvivedCleanup;
        cleaned = true;
        if (report_failure) |err| return err;
        if (d.profiling and !passed) return error.IncompleteProfile;
    }
    fn writeProfile(d: *Desktop, ctx: *up.core.GameContext) !void {
        // Host loop has finished: serialize and validate real saved bytes here.
        const allocator = try ctx.requireAllocator();
        var bytes: [save.size]u8 = .{0} ** save.size;
        const persisted = try (try ctx.requireSaveData()).read(save.key, &bytes);
        const expected = save.encode(d.state.state, d.state.settings);
        const hex = std.fmt.bytesToHex(bytes, .lower);
        const c = if (d.capture_saves) |recording| &recording.collector else null;
        const json = try std.json.Stringify.valueAlloc(allocator, .{
            .schema = 1,
            .optimize = @tagName(@import("builtin").mode),
            .instrumented = c != null,
            .start_tick = d.profile_start,
            .end_tick = d.tick,
            .state_hash = state_digest(&d.state),
            .save_hex = hex[0 .. persisted.len * 2],
            .updates = if (c) |collector| collector.updates[0..collector.update_count] else &.{},
            .operations = if (c) |collector| collector.operations[0..collector.operation_count] else &.{},
            .dropped_updates = if (c) |collector| collector.dropped_updates else 0,
            .dropped_operations = if (c) |collector| collector.dropped_operations else 0,
        }, .{});
        defer allocator.free(json);
        var path: [1024]u8 = undefined;
        try std.fs.cwd().writeFile(.{ .sub_path = try std.fmt.bufPrint(&path, "{s}/profile-observations.json", .{d.output.?}), .data = json });
        // Retain operation errors before rejecting a failed/inconsistent save.
        if (!std.mem.eql(u8, persisted, &expected)) return error.ProfileSavedBytesMismatch;
        _ = try save.decode(persisted);
    }
};
pub fn main() !void {
    try sdl.playGame(Desktop);
    if (!passed or !cleaned) return error.IncompleteNativeVerification;
    std.debug.print("ashen native cleanup verified\n", .{});
}

test "profile report failure still releases resources and bounds short saved bytes" {
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    for ([_]bool{ false, true }) |short_blob| {
        var input = up.input.Input{};
        var audio = try up.core.Audio.init(allocator, .{});
        defer audio.deinit();
        var store: up.testSupport.InMemorySaveStore = undefined;
        store.init(allocator);
        defer store.deinit();
        if (short_blob) try store.capability().write(save.key, "bad");
        var ctx = up.core.GameContext.init(&input);
        ctx.allocator = allocator;
        ctx.audio = &audio;
        ctx.save_data = store.capability();
        var desktop = Desktop{ .profiling = true, .tick = 240 };
        try desktop.state.init(&ctx);
        desktop.output = try temporary.dir.realpathAlloc(allocator, ".");
        desktop.capture_saves = try allocator.create(observations.Capture);
        try desktop.capture_saves.?.init();
        passed = false;
        cleaned = false;
        defer {
            passed = false;
            cleaned = false;
        }
        try std.testing.expectError(if (short_blob) error.ProfileSavedBytesMismatch else error.NotFound, desktop.deinit(&ctx));
        try std.testing.expect(cleaned);
        try std.testing.expect(desktop.state.actions == null);
        try std.testing.expect(desktop.output == null and desktop.capture_saves == null);
        try std.testing.expect(!audio.hasActivePlayback());
        if (short_blob) {
            const json = try temporary.dir.readFileAlloc(allocator, "profile-observations.json", 64 * 1024);
            defer allocator.free(json);
            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
            defer parsed.deinit();
            try std.testing.expectEqualStrings("626164", parsed.value.object.get("save_hex").?.string);
        }
    }
}
