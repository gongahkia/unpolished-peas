//! Portable audio-lifetime measurements and conformance checks.
const std = @import("std");
const builtin = @import("builtin");
const up = @import("unpolished-peas");
const Audio = up.core.Audio;
const effect_bytes = @embedFile("assets/blip.wav");
const music_bytes = @embedFile("assets/tone.ogg");
const scene = @import("audio_lifetime_game.zig");
const tiny_wav = [_]u8{
    'R',  'I',  'F', 'F',  44, 0,    0, 0, 'W', 'A',  'V', 'E',
    'f',  'm',  't', ' ',  16, 0,    0, 0, 1,   0,    1,   0,
    0x80, 0xbb, 0,   0,    0,  0x77, 1, 0, 2,   0,    16,  0,
    'd',  'a',  't', 'a',  8,  0,    0, 0, 0,   0x20, 0,   0x40,
    0,    0x60, 0,   0xe0,
};

const Tracker = struct {
    parent: std.mem.Allocator,
    live_bytes: usize = 0,
    peak_bytes: usize = 0,
    operations: usize = 0,
    allocation_attempts: usize = 0,

    fn allocator(self: *Tracker) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn changed(self: *Tracker, old: usize, new: usize) void {
        self.live_bytes = self.live_bytes - old + new;
        self.peak_bytes = @max(self.peak_bytes, self.live_bytes);
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Tracker = @ptrCast(@alignCast(ctx));
        self.operations += 1;
        self.allocation_attempts += 1;
        const result = self.parent.rawAlloc(len, alignment, ret) orelse return null;
        self.changed(0, len);
        return result;
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) bool {
        const self: *Tracker = @ptrCast(@alignCast(ctx));
        self.operations += 1;
        self.allocation_attempts += 1;
        if (!self.parent.rawResize(memory, alignment, len, ret)) return false;
        self.changed(memory.len, len);
        return true;
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) ?[*]u8 {
        const self: *Tracker = @ptrCast(@alignCast(ctx));
        self.operations += 1;
        self.allocation_attempts += 1;
        const result = self.parent.rawRemap(memory, alignment, len, ret) orelse return null;
        self.changed(memory.len, len);
        return result;
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Tracker = @ptrCast(@alignCast(ctx));
        self.operations += 1;
        self.parent.rawFree(memory, alignment, ret);
        self.changed(memory.len, 0);
    }
};

const Sample = struct { cycles: u32, sound_slots: u32, music_slots: u32, live_bytes: u32 };
const Report = struct { retained: [4]Sample, released: [4]Sample, pcm_hash: u64, allocation_failures: u32 };
var report: Report = undefined;
var stage: u32 = 0;

fn check(condition: bool) !void {
    if (!condition) return error.AudioLifetimeMismatch;
}

fn measureCycles(allocator: std.mem.Allocator, release: bool) ![4]Sample {
    var tracked = Tracker{ .parent = allocator };
    var observations: [4]Sample = undefined;
    {
        var audio = try Audio.init(tracked.allocator(), .{});
        defer audio.deinit();
        var buffer: [800]up.assets.AudioSample = undefined;
        var sample: usize = 0;
        for (0..256) |i| {
            const sound = try audio.loadWav(effect_bytes);
            const music = try audio.loadMusic(music_bytes, .{});
            const playback = try audio.play(sound, .{});
            _ = try audio.playMusic(music, .{});
            try audio.mix(&buffer);
            _ = audio.stop(playback);
            _ = audio.stopMusic();
            if (release) {
                try check(audio.unloadSound(sound) and audio.unloadMusic(music));
                try check(!audio.unloadSound(sound) and !audio.unloadMusic(music));
            }
            if (i == 0 or i == 7 or i == 63 or i == 255) {
                observations[sample] = .{ .cycles = @intCast(i + 1), .sound_slots = @intCast(audio.sounds.items.len), .music_slots = @intCast(audio.music_sources.items.len), .live_bytes = @intCast(tracked.live_bytes) };
                sample += 1;
            }
        }
    }
    try check(tracked.live_bytes == 0);
    return observations;
}

fn wave(index: usize) f32 {
    return ([_]f32{ 0.25, 0.5, 0.75, -0.25 })[index % 4];
}

fn expectControl(audio: *Audio, gain: f32, hash: *std.hash.Fnv1a_64) !void {
    var samples: [16]up.assets.AudioSample = undefined;
    try audio.mix(&samples);
    for (samples, 0..) |sample, i| {
        try check(sample.left == wave(i) * gain and sample.right == sample.left);
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, @bitCast(sample.left), .little);
        hash.update(&bytes);
    }
}

fn soundCases(allocator: std.mem.Allocator, hash: *std.hash.Fnv1a_64) !void {
    var tracked = Tracker{ .parent = allocator };
    var audio = try Audio.init(tracked.allocator(), .{});
    defer audio.deinit();
    const persistent = try audio.loadWav(&tiny_wav);
    const survivor = try audio.play(persistent, .{ .loop = true, .volume = 0.25 });
    const sound = try audio.loadWav(&tiny_wav);
    const a = try audio.play(sound, .{ .loop = true });
    const b = try audio.play(sound, .{});
    const c = try audio.play(sound, .{ .loop = true });
    try check(audio.mixer.pause(c));
    const bytes_before = tracked.live_bytes;
    const attempts = tracked.allocation_attempts;
    audio.setAvailability(.unavailable);
    try check(audio.unloadSound(sound));
    try check(tracked.allocation_attempts == attempts);
    try check(bytes_before - tracked.live_bytes == 4 * @sizeOf(up.assets.AudioSample));
    try check(!audio.stop(a) and !audio.stop(b) and !audio.mixer.resumePlayback(c));
    try check(!audio.unloadSound(sound));
    try check(!audio.unloadSound(.{ .index = 9999, .generation = 1 }));
    try check(!audio.unloadSound(.{ .index = sound.index, .generation = 0 }));
    audio.setAvailability(.ready);
    if (audio.play(sound, .{})) |_| return error.StaleSoundAccepted else |err| try check(err == error.InvalidSound);
    try expectControl(&audio, 0.25, hash);
    const replacement = try audio.loadWav(&tiny_wav);
    try check(replacement.index == sound.index and replacement.generation != sound.generation);
    try check(!audio.unloadSound(sound));
    const d = try audio.play(replacement, .{ .loop = true, .volume = 0.25 });
    try check(!audio.stop(a)); // playback slots were reused too.
    try expectControl(&audio, 0.5, hash);
    try check(audio.unloadSound(replacement) and !audio.stop(d));
    try expectControl(&audio, 0.25, hash);
    try check(audio.stop(survivor));
    try check(audio.unloadSound(persistent));
    try expectControl(&audio, 0, hash);
}

const Mode = enum { playing, paused, stopped, ended, replaced, not_started };
fn musicCase(allocator: std.mem.Allocator, format: Audio.MusicFormat, mode: Mode, hash: *std.hash.Fnv1a_64) !void {
    var tracked = Tracker{ .parent = allocator };
    var audio = try Audio.init(tracked.allocator(), .{});
    defer audio.deinit();
    const ui = try audio.loadWav(&tiny_wav);
    _ = try audio.play(ui, .{ .loop = true, .volume = 0.25 });
    const bytes: []const u8 = if (format == .ogg) music_bytes else &tiny_wav;
    const music = try audio.loadMusic(bytes, .{ .format = format });
    var old_playback: ?up.assets.PlaybackHandle = null;
    if (mode != .not_started) {
        old_playback = try audio.playMusic(music, .{ .loop = mode != .ended, .volume = 0.125 });
        // Independent full decode verifies actual stream output before release.
        var decoded = if (format == .ogg) try up.assets.Sound.decodeOgg(allocator, bytes) else try up.assets.Sound.decodeWav(allocator, bytes);
        defer decoded.deinit();
        var output: [16]up.assets.AudioSample = undefined;
        try audio.mix(&output);
        for (output, 0..) |sample, i| {
            const frame: usize = @intFromFloat(@as(f64, @floatFromInt(i)) * @as(f64, @floatFromInt(decoded.sample_rate)) / 48_000.0);
            const expected = if (mode == .ended and frame >= decoded.frames.len) up.assets.AudioSample{} else decoded.frames[frame % decoded.frames.len];
            try check(@abs(sample.left - (wave(i) * 0.25 + expected.left * 0.125)) < 0.000001);
            try check(@abs(sample.right - (wave(i) * 0.25 + expected.right * 0.125)) < 0.000001);
        }
    }
    switch (mode) {
        .paused => try check(audio.pauseMusic()),
        .stopped => _ = audio.stopMusic(),
        .ended => {
            var output: [1024]up.assets.AudioSample = undefined;
            var rounds: usize = 0;
            while (audio.musicState() != .stopped and rounds < 256) : (rounds += 1) try audio.mix(&output);
            try check(audio.musicState() == .stopped);
        },
        else => {},
    }
    var unrelated: ?Audio.MusicHandle = null;
    if (mode == .replaced) {
        unrelated = try audio.loadMusic(&tiny_wav, .{ .format = .wav });
        _ = try audio.playMusic(unrelated.?, .{ .volume = 0.125 });
    }
    const attempts = tracked.allocation_attempts;
    const before = tracked.live_bytes;
    audio.setAvailability(.blocked);
    try check(audio.unloadMusic(music));
    try check(tracked.allocation_attempts == attempts and before - tracked.live_bytes >= bytes.len);
    if (old_playback) |playback| try check(!audio.stop(playback));
    try check(audio.musicState() == if (mode == .replaced) Audio.MusicState.playing else Audio.MusicState.stopped);
    try check(!audio.unloadMusic(music));
    try check(!audio.unloadMusic(.{ .index = 9999, .generation = 1 }));
    try check(!audio.unloadMusic(.{ .index = music.index, .generation = 0 }));
    audio.setAvailability(.ready);
    if (audio.playMusic(music, .{})) |_| return error.StaleMusicAccepted else |err| try check(err == error.InvalidMusic);
    try expectControl(&audio, if (mode == .replaced) 0.375 else 0.25, hash);
    const replacement = try audio.loadMusic(bytes, .{ .format = format });
    try check(replacement.index == music.index and replacement.generation != music.generation);
    try check(!audio.unloadMusic(music));
    _ = try audio.playMusic(replacement, .{});
    try check(audio.unloadMusic(replacement) and audio.musicState() == .stopped);
    if (unrelated) |value| try check(audio.unloadMusic(value));
    try expectControl(&audio, 0.25, hash);
}

fn exhaustion(allocator: std.mem.Allocator) !void {
    var audio = try Audio.init(allocator, .{});
    defer audio.deinit();
    const stale = try audio.loadWav(&tiny_wav);
    try check(audio.unloadSound(stale));
    audio.next_generation = std.math.maxInt(u32);
    const last = try audio.loadWav(&tiny_wav);
    try check(!audio.unloadSound(stale));
    if (audio.loadWav(&tiny_wav)) |_| return error.ExpectedHandleExhaustion else |err| try check(err == error.AudioHandleExhausted);
    _ = try audio.play(last, .{});
    try check(audio.unloadSound(last));
    if (audio.loadWav(&tiny_wav)) |_| return error.ExpectedHandleExhaustion else |err| try check(err == error.AudioHandleExhausted);
    const music = try audio.loadMusic(&tiny_wav, .{ .format = .wav });
    try check(audio.unloadMusic(music));
    audio.next_music_generation = std.math.maxInt(u32);
    const final_music = try audio.loadMusic(&tiny_wav, .{ .format = .wav });
    try check(!audio.unloadMusic(music));
    if (audio.loadMusic(music_bytes, .{})) |_| return error.ExpectedHandleExhaustion else |err| try check(err == error.AudioHandleExhausted);
    try check(audio.unloadMusic(final_music));
}

// Run at every allocation-failure point natively AND in Wasm. On a failed
// replacement, verify the persistent resource still mixes its exact PCM.
fn allocationScenario(allocator: std.mem.Allocator) !void {
    var audio = try Audio.init(allocator, .{});
    defer audio.deinit();
    const ui = try audio.loadWav(&tiny_wav);
    _ = try audio.play(ui, .{ .loop = true, .volume = 0.25 });
    var hash = std.hash.Fnv1a_64.init();
    const sound = audio.loadWav(&tiny_wav) catch |err| {
        try expectControl(&audio, 0.25, &hash);
        return err;
    };
    try check(audio.unloadSound(sound));
    const reused = audio.loadWav(&tiny_wav) catch |err| {
        try expectControl(&audio, 0.25, &hash);
        return err;
    };
    defer _ = audio.unloadSound(reused);
    const music = audio.loadMusic(music_bytes, .{}) catch |err| {
        try expectControl(&audio, 0.25, &hash);
        return err;
    };
    defer _ = audio.unloadMusic(music);
    _ = try audio.playMusic(music, .{});
    try check(audio.unloadMusic(music));
    const next = try audio.loadMusic(music_bytes, .{});
    defer _ = audio.unloadMusic(next);
    _ = try audio.playMusic(next, .{});
    const incoming = try audio.loadMusic(music_bytes, .{});
    defer _ = audio.unloadMusic(incoming);
    _ = audio.playMusic(incoming, .{}) catch |err| {
        try check(audio.musicState() == .playing);
        return err;
    };
}

fn failures(allocator: std.mem.Allocator) !u32 {
    var index: usize = 0;
    while (index < 128) : (index += 1) {
        var tracked = Tracker{ .parent = allocator };
        var failing = std.testing.FailingAllocator.init(tracked.allocator(), .{ .fail_index = index });
        const result = allocationScenario(failing.allocator());
        try check(tracked.live_bytes == 0);
        if (result) |_| return @intCast(index) else |err| try check(err == error.OutOfMemory);
    }
    return error.AllocationFailureCoverageIncomplete;
}

fn sceneScenario(allocator: std.mem.Allocator) !void {
    const runner = try up.testSupport.HeadlessGameRunner(scene.Game).init(allocator, scene.width, scene.height);
    defer runner.deinit();
    const persistent = runner.game.ui_sound.?;
    for (0..64) |_| try runner.game.changeScene(&runner.context);
    try check(runner.audio.sounds.items.len == 3 and runner.audio.music_sources.items.len == 2);
    _ = try runner.audio.play(persistent, .{});
    try runner.draw(0);
    try runner.game.deinit(&runner.context);
    try check(!runner.audio.hasActivePlayback() and !runner.audio.unloadSound(persistent));
}

fn verify(allocator: std.mem.Allocator) !Report {
    stage = 1;
    var hash = std.hash.Fnv1a_64.init();
    try soundCases(allocator, &hash);
    var mode_index: u32 = 0;
    for ([_]Audio.MusicFormat{ .wav, .ogg }) |format| {
        for (std.enums.values(Mode)) |mode| {
            stage = 2 + mode_index;
            try musicCase(allocator, format, mode, &hash);
            mode_index += 1;
        }
    }
    stage = 20;
    try exhaustion(allocator);
    stage = 21;
    const failure_count = try failures(allocator);
    stage = 22;
    try sceneScenario(allocator);
    stage = 23;
    const retained = try measureCycles(allocator, false);
    const released = try measureCycles(allocator, true);
    for (retained) |value| try check(value.sound_slots == value.cycles and value.music_slots == value.cycles);
    for (released) |value| try check(value.sound_slots == 1 and value.music_slots == 1 and value.live_bytes == released[0].live_bytes);
    return .{ .retained = retained, .released = released, .pcm_hash = hash.final(), .allocation_failures = failure_count };
}

test "portable unload, PCM, reuse, bounds and allocation failure conformance" {
    report = verify(std.testing.allocator) catch |err| {
        std.debug.print("audio-lifetime stage={d}: {s}\n", .{ stage, @errorName(err) });
        return err;
    };
}

test "scene-transition example cleans up every failed initialization" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, sceneAllocationScenario, .{});
}

fn sceneAllocationScenario(allocator: std.mem.Allocator) !void {
    const runner = try up.testSupport.HeadlessGameRunner(scene.Game).init(allocator, scene.width, scene.height);
    defer runner.deinit();
    for (0..4) |_| try runner.game.changeScene(&runner.context);
}

pub export fn audio_lifetime_run() u32 {
    report = verify(if (builtin.target.cpu.arch == .wasm32) std.heap.wasm_allocator else std.heap.page_allocator) catch return 1;
    return 0;
}
pub export fn audio_lifetime_stage() u32 {
    return stage;
}
pub export fn audio_lifetime_hash() u64 {
    return report.pcm_hash;
}
pub export fn audio_lifetime_failures() u32 {
    return report.allocation_failures;
}
pub export fn audio_lifetime_sample(release: u32, index: u32, field: u32) u32 {
    if (index >= 4) return 0;
    const sample = if (release != 0) report.released[index] else report.retained[index];
    return switch (field) {
        0 => sample.cycles,
        1 => sample.sound_slots,
        2 => sample.music_slots,
        3 => sample.live_bytes,
        else => 0,
    };
}

pub fn main() !void {
    if (comptime builtin.os.tag == .freestanding) return;
    report = verify(std.heap.page_allocator) catch |err| {
        std.debug.print("audio-lifetime stage={d}: {s}\n", .{ stage, @errorName(err) });
        return err;
    };
    var hash_text: [32]u8 = undefined;
    const json = try std.json.Stringify.valueAlloc(std.heap.page_allocator, .{ .retained = report.retained, .released = report.released, .pcm_hash = try std.fmt.bufPrint(&hash_text, "{d}", .{report.pcm_hash}), .allocation_failures = report.allocation_failures }, .{});
    defer std.heap.page_allocator.free(json);
    try std.fs.File.stdout().writeAll(json);
    try std.fs.File.stdout().writeAll("\n");
}
