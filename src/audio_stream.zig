const builtin = @import("builtin");
const std = @import("std");
const audio = @import("audio.zig");

pub const Config = struct {
    frames_per_submit: usize = 1024,
};

/// Owns one interleaved stereo mix buffer. Browser builds submit that buffer to
/// the host audio queue; native adapters retain ownership of their device sink.
pub const AudioStream = struct {
    allocator: std.mem.Allocator,
    samples: []audio.AudioSample,

    pub fn init(allocator: std.mem.Allocator, config: Config) !AudioStream {
        if (config.frames_per_submit == 0 or config.frames_per_submit > 16 * 1024) return error.InvalidAudioSubmitFrames;
        return .{ .allocator = allocator, .samples = try allocator.alloc(audio.AudioSample, config.frames_per_submit) };
    }

    pub fn deinit(self: *AudioStream) void {
        self.allocator.free(self.samples);
        self.* = undefined;
    }

    /// Mixes exactly one buffer. On Wasm, false means the browser audio context
    /// has not been activated by a user gesture or its bounded queue is full.
    pub fn submit(self: *AudioStream, mixer: *audio.AudioMixer) !bool {
        try mixer.mix(self.samples);
        return switch (builtin.target.cpu.arch) {
            .wasm32 => BrowserHost.submit(@intCast(@intFromPtr(self.samples.ptr)), try byteLength(self.samples)),
            else => error.BrowserAudioUnavailable,
        };
    }
};

const BrowserHost = struct {
    extern "env" fn up_host_audio_submit(source: u32, byte_len: u32) i32;

    fn submit(source: u32, byte_len: u32) bool {
        return up_host_audio_submit(source, byte_len) == 0;
    }
};

fn byteLength(samples: []const audio.AudioSample) !u32 {
    return std.math.cast(u32, std.mem.sliceAsBytes(samples).len) orelse error.AudioSubmitTooLarge;
}

test "audio stream owns a bounded mix buffer" {
    var stream = try AudioStream.init(std.testing.allocator, .{ .frames_per_submit = 4 });
    defer stream.deinit();
    try std.testing.expectEqual(@as(usize, 4), stream.samples.len);
    try std.testing.expectError(error.InvalidAudioSubmitFrames, AudioStream.init(std.testing.allocator, .{ .frames_per_submit = 0 }));
    var mixer = try audio.AudioMixer.init(std.testing.allocator, .{});
    defer mixer.deinit();
    try std.testing.expectError(error.BrowserAudioUnavailable, stream.submit(&mixer));
}
