const std = @import("std");
const up = @import("unpolished-peas");

const click_wav = [_]u8{
    'R',  'I',  'F', 'F', 40,   0,    0,    0, 'W', 'A', 'V',  'E',
    'f',  'm',  't', ' ', 16,   0,    0,    0, 1,   0,   1,    0,
    0x80, 0xbb, 0,   0,   0x00, 0x77, 0x01, 0, 2,   0,   16,   0,
    'd',  'a',  't', 'a', 4,    0,    0,    0, 0,   0,   0xff, 0x7f,
};

test "public GameProtocol audio loads once, overlaps playback, and remains recoverable" {
    var audio = try up.core.Audio.init(std.testing.allocator, .{});
    defer audio.deinit();

    const sound = try audio.loadWav(&click_wav);
    const first = try audio.play(sound, .{ .volume = 0.5 });
    const second = try audio.play(sound, .{ .volume = 0.5 });
    try std.testing.expect(first.id != second.id);

    var samples: [2]up.assets.AudioSample = undefined;
    try audio.mix(&samples);
    try std.testing.expect(samples[1].left > 0.9);
    try std.testing.expect(samples[1].right > 0.9);
    try std.testing.expect(audio.stop(first));
    try std.testing.expect(!audio.stop(first));

    audio.setAvailability(.blocked);
    try std.testing.expectError(error.AudioUnavailable, audio.play(sound, .{}));
    audio.setAvailability(.unavailable);
    try std.testing.expectError(error.AudioUnavailable, audio.play(sound, .{}));
    audio.setAvailability(.ready);
    try std.testing.expectError(error.InvalidVolume, audio.play(sound, .{ .volume = 1.01 }));
    try std.testing.expectError(error.InvalidSound, audio.play(.{ .index = 99, .generation = 1 }, .{}));
}
