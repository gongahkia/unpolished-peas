//! Optional CPU workload profile; observations never enter saves or game state.
const std = @import("std");
const builtin = @import("builtin");
const up = @import("unpolished-peas");
const game = @import("game.zig");
const Counter = @import("profile_allocator.zig").CountingAllocator;
const state_digest = @import("profile_state.zig").digest;
const save = @import("save.zig");
const Sample = struct {
    tick: usize,
    update_ns: u64,
    draw_ns: u64,
    audio_ns: u64,
    update_allocations: u64,
    draw_allocations: u64,
    audio_allocations: u64,
    allocated_bytes: u64,
    room: u8,
    enemies: usize,
    shots: usize,
    rings: usize,
    boss_phase_two: bool,
    state_hash: u64,
    save_bytes: [save.size]u8,
};
pub fn main() !void {
    if (builtin.mode != .ReleaseFast) return error.ProfileRequiresReleaseFast;
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 3) return error.ExpectedReplayAndOutput;
    const bytes = try std.fs.cwd().readFileAlloc(allocator, args[1], 16 * 1024 * 1024);
    defer allocator.free(bytes);
    var replay = try up.preview.developer.parseInputReplay(allocator, bytes);
    defer replay.deinit(allocator);
    if (replay.fixed_hz != 60 or replay.simulation_seed != game.default_seed) return error.ReplayEnvironmentMismatch;
    const samples = try allocator.alloc(Sample, replay.frames.len);
    defer allocator.free(samples);
    var counter = Counter.init(allocator);
    const r = try up.testSupport.HeadlessGameRunner(game.Game).initSeeded(counter.allocator(), game.width, game.height, game.default_seed);
    var alive = true;
    defer if (alive) r.deinit();
    // Structural trace recording is a test facility, not production rendering.
    r.canvas.detachTrace();
    const init_allocations = counter.allocation_events;
    const init_bytes = counter.allocated_bytes;
    var pcm: [800]up.assets.AudioSample = undefined;
    var timer = try std.time.Timer.start();
    for (replay.frames, 0..) |frame, index| {
        counter.reset();
        timer.reset();
        try r.step(frame, 1.0 / 60.0);
        const update_ns = timer.lap();
        const update_allocations = counter.allocation_events;
        const update_bytes = counter.allocated_bytes;
        counter.reset();
        try r.draw(0);
        const draw_ns = timer.lap();
        const draw_allocations = counter.allocation_events;
        const draw_bytes = counter.allocated_bytes;
        counter.reset();
        try r.audio.mix(&pcm);
        const audio_ns = timer.lap();
        std.mem.doNotOptimizeAway(&pcm);
        var enemies: usize = 0;
        var shots: usize = 0;
        var rings: usize = 0;
        var phase_two = false;
        for (r.game.state.enemies) |e| {
            if (e.hp > 0) enemies += 1;
            if (e.kind == .warden and e.phase == 2) phase_two = true;
        }
        for (r.game.state.shots) |shot| if (shot.life > 0) {
            shots += 1;
        };
        for (r.game.state.rings) |ring| if (ring.alive) {
            rings += 1;
        };
        samples[index] = .{ .tick = index, .update_ns = update_ns, .draw_ns = draw_ns, .audio_ns = audio_ns, .update_allocations = update_allocations, .draw_allocations = draw_allocations, .audio_allocations = counter.allocation_events, .allocated_bytes = update_bytes + draw_bytes + counter.allocated_bytes, .room = r.game.state.room, .enemies = enemies, .shots = shots, .rings = rings, .boss_phase_two = phase_two, .state_hash = state_digest(&r.game), .save_bytes = save.encode(r.game.state, r.game.settings) };
    }
    if (!r.game.state.completed or r.game.save_failed) return error.ProfileRouteDidNotWin;
    const peak_bytes = counter.peak_bytes;
    const ending_live_bytes = counter.live_bytes;
    r.deinit();
    alive = false;
    if (counter.live_bytes != 0) return error.ProfileResourceLeak;
    const json = try std.json.Stringify.valueAlloc(allocator, .{ .optimize = @tagName(builtin.mode), .width = game.width, .height = game.height, .fixed_hz = 60, .audio_sample_rate = 48000, .audio_frames_per_tick = 800, .init_allocations = init_allocations, .init_allocated_bytes = init_bytes, .peak_bytes = peak_bytes, .ending_live_bytes = ending_live_bytes, .live_bytes_after_cleanup = counter.live_bytes, .samples = samples }, .{});
    defer allocator.free(json);
    try std.fs.cwd().writeFile(.{ .sub_path = args[2], .data = json });
}
