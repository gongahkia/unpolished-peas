const std = @import("std");
const root = @import("unpolished-peas");

pub const AudioSample = struct { left: f32 = 0, right: f32 = 0 };

pub const AudioMixer = struct {
    pub const Config = struct { sample_rate: u32 = 48_000 };

    const Playback = struct {
        id: u64,
        sound: *const root.assets.Sound,
        position: f64 = 0,
        volume: f32,
        loop: bool,
        active: bool = true,
        paused: bool = false,
    };

    allocator: std.mem.Allocator,
    sample_rate: u32,
    playbacks: std.ArrayListUnmanaged(Playback) = .{},
    next_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator, config: Config) !AudioMixer {
        if (config.sample_rate == 0) return error.InvalidSampleRate;
        return .{ .allocator = allocator, .sample_rate = config.sample_rate };
    }

    pub fn deinit(self: *AudioMixer) void {
        self.playbacks.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn playSound(self: *AudioMixer, sound: *const root.assets.Sound, options: root.assets.SoundOptions) !root.assets.PlaybackHandle {
        if (!std.math.isFinite(options.volume) or options.volume < 0 or options.volume > 1) return error.InvalidVolume;
        if (sound.frames.len == 0) return error.EmptySound;
        const id = self.next_id;
        self.next_id +%= 1;
        if (self.next_id == 0) self.next_id = 1;
        const playback = Playback{ .id = id, .sound = sound, .volume = options.volume, .loop = options.loop };
        for (self.playbacks.items, 0..) |*slot, index| if (!slot.active) {
            slot.* = playback;
            return .{ .index = index, .id = id };
        };
        try self.playbacks.append(self.allocator, playback);
        return .{ .index = self.playbacks.items.len - 1, .id = id };
    }

    pub fn stop(self: *AudioMixer, handle: root.assets.PlaybackHandle) bool {
        const playback = self.get(handle) orelse return false;
        playback.active = false;
        return true;
    }

    pub fn mix(self: *AudioMixer, out: []AudioSample) !void {
        @memset(out, .{});
        for (self.playbacks.items) |*playback| {
            if (!playback.active or playback.paused) continue;
            const step = @as(f64, @floatFromInt(playback.sound.sample_rate)) / @as(f64, @floatFromInt(self.sample_rate));
            for (out) |*destination| {
                const index: usize = @intFromFloat(playback.position);
                if (index >= playback.sound.frames.len) {
                    if (!playback.loop) {
                        playback.active = false;
                        break;
                    }
                    playback.position = @mod(playback.position, @as(f64, @floatFromInt(playback.sound.frames.len)));
                }
                const source = playback.sound.frames[@intFromFloat(playback.position)];
                destination.left = clamp(destination.left + source.left * playback.volume);
                destination.right = clamp(destination.right + source.right * playback.volume);
                playback.position += step;
            }
        }
    }

    fn get(self: *AudioMixer, handle: root.assets.PlaybackHandle) ?*Playback {
        if (handle.index >= self.playbacks.items.len) return null;
        const playback = &self.playbacks.items[handle.index];
        return if (playback.active and playback.id == handle.id) playback else null;
    }
};

fn clamp(value: f32) f32 {
    return std.math.clamp(value, -1, 1);
}

test "desktop mixer follows the stable audio fixture" {
    const Fixture = struct {
        valid_wav_base64: []const u8,
        invalid_wav_base64: []const u8,
        outcomes: struct {
            load: []const u8,
            play: []const u8,
            stop: []const u8,
            stop_stale: []const u8,
            invalid_load: []const u8,
        },
    };
    const source = try std.fs.cwd().readFileAlloc(std.testing.allocator, "src/fixtures/audio/stable-audio-v1.json", 4096);
    defer std.testing.allocator.free(source);
    var fixture = try std.json.parseFromSlice(Fixture, std.testing.allocator, source, .{ .ignore_unknown_fields = true });
    defer fixture.deinit();
    try std.testing.expectEqualStrings("ok", fixture.value.outcomes.load);
    try std.testing.expectEqualStrings("ok", fixture.value.outcomes.play);
    try std.testing.expectEqualStrings("ok", fixture.value.outcomes.stop);
    try std.testing.expectEqualStrings("rejected", fixture.value.outcomes.stop_stale);
    try std.testing.expectEqualStrings("rejected", fixture.value.outcomes.invalid_load);
    const valid_len = try std.base64.standard.Decoder.calcSizeForSlice(fixture.value.valid_wav_base64);
    const valid = try std.testing.allocator.alloc(u8, valid_len);
    defer std.testing.allocator.free(valid);
    try std.base64.standard.Decoder.decode(valid, fixture.value.valid_wav_base64);
    var sound = try root.assets.Sound.decodeWav(std.testing.allocator, valid);
    defer sound.deinit();
    var mixer = try AudioMixer.init(std.testing.allocator, .{});
    defer mixer.deinit();
    const handle = try mixer.playSound(&sound, .{});
    try std.testing.expect(mixer.stop(handle));
    try std.testing.expect(!mixer.stop(handle));
    const invalid_len = try std.base64.standard.Decoder.calcSizeForSlice(fixture.value.invalid_wav_base64);
    const invalid = try std.testing.allocator.alloc(u8, invalid_len);
    defer std.testing.allocator.free(invalid);
    try std.base64.standard.Decoder.decode(invalid, fixture.value.invalid_wav_base64);
    try std.testing.expectError(error.InvalidWav, root.assets.Sound.decodeWav(std.testing.allocator, invalid));
}
