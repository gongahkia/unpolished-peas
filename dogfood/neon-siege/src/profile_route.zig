//! Optional CPU observations, outside game state and saves.
const std = @import("std");
const up = @import("unpolished-peas");
const game = @import("game.zig");
const Counter = @import("profile_allocator.zig").CountingAllocator;
const Sample = struct { tick: usize, update_ns: u64, draw_ns: u64, audio_ns: u64, allocations: u64, allocated_bytes: u64, active: bool, playing: bool, workload_a: usize, workload_b: usize };
pub fn main() !void {
    if (@import("builtin").mode != .ReleaseFast) return error.RequiresReleaseFast;
    const a = std.heap.page_allocator;
    const args = try std.process.argsAlloc(a);
    defer std.process.argsFree(a, args);
    if (args.len != 3) return error.ExpectedReplayAndOutput;
    const bytes = try std.fs.cwd().readFileAlloc(a, args[1], 16 * 1024 * 1024);
    defer a.free(bytes);
    var replay = try up.preview.developer.parseInputReplay(a, bytes);
    defer replay.deinit(a);
    if (replay.fixed_hz != 60 or replay.simulation_seed != game.default_seed) return error.ReplayEnvironmentMismatch;
    const samples = try a.alloc(Sample, replay.frames.len);
    defer a.free(samples);
    var counter = Counter.init(a);
    const r = try up.testSupport.HeadlessGameRunner(game.Game).initSeeded(counter.allocator(), game.width, game.height, game.default_seed);
    var alive = true;
    defer if (alive) r.deinit();
    r.canvas.detachTrace();
    const init_allocations = counter.allocation_events;
    const init_bytes = counter.allocated_bytes;
    var timer = try std.time.Timer.start();
    var pcm: [800]up.assets.AudioSample = undefined;
    for (replay.frames, 0..) |frame, i| {
        counter.reset();
        timer.reset();
        try r.step(frame, 1.0 / 60.0);
        const update_ns = timer.lap();
        try r.draw(0);
        const draw_ns = timer.lap();
        try r.audio.mix(&pcm);
        const audio_ns = timer.lap();
        std.mem.doNotOptimizeAway(&pcm);
        var enemies: usize = 0;
        var shots: usize = 0;
        for (r.game.enemies) |e| {
            if (e.active) enemies += 1;
        }
        for (r.game.projectiles) |e| {
            if (e.active) shots += 1;
        }
        samples[i] = .{ .tick = i, .update_ns = update_ns, .draw_ns = draw_ns, .audio_ns = audio_ns, .allocations = counter.allocation_events, .allocated_bytes = counter.allocated_bytes, .playing = r.game.screen == .playing and !r.game.game_over, .active = r.game.wave >= 3 and r.game.screen == .playing and !r.game.game_over, .workload_a = enemies, .workload_b = shots };
    }
    const peak = counter.peak_bytes;
    const ending = counter.live_bytes;
    r.deinit();
    alive = false;
    if (counter.live_bytes != 0) return error.ResourceLeak;
    const json = try std.json.Stringify.valueAlloc(a, .{ .game = "neon-siege", .optimize = "ReleaseFast", .width = game.width, .height = game.height, .audio_sample_rate = 48000, .audio_frames_per_tick = 800, .allocation_scope = "Game/headless runner/Canvas/audio/in-memory SaveStore; excludes replay, observation arrays, C allocator, driver and OS", .init_allocations = init_allocations, .init_allocated_bytes = init_bytes, .peak_bytes = peak, .ending_live_bytes = ending, .live_bytes_after_cleanup = counter.live_bytes, .samples = samples }, .{});
    defer a.free(json);
    try std.fs.cwd().writeFile(.{ .sub_path = args[2], .data = json });
}
