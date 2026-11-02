const std = @import("std");
const up = @import("unpolished-peas");

const tone_ogg = @embedFile("examples/assets/tone.ogg");

pub export fn up_browser_ogg_decode_smoke() i32 {
    var sound = up.assets.Sound.decodeOgg(std.heap.wasm_allocator, tone_ogg) catch return -1;
    defer sound.deinit();
    if (sound.sample_rate == 0 or sound.frames.len == 0) return -2;
    var audio = up.core.Audio.init(std.heap.wasm_allocator, .{ .sample_rate = sound.sample_rate }) catch return -3;
    defer audio.deinit();
    const music = audio.loadMusic(tone_ogg, .{}) catch return -4;
    _ = audio.playMusic(music, .{}) catch return -5;
    var output: [256]up.assets.AudioSample = undefined;
    audio.mix(&output) catch return -6;
    for (output) |sample| {
        if (sample.left != 0 or sample.right != 0) return 0;
    }
    if (!audio.pauseMusic() or audio.musicState() != .paused) return -7;
    if (!audio.resumeMusic() or audio.musicState() != .playing) return -8;
    if (!audio.stopMusic() or audio.musicState() != .stopped) return -9;
    var blocked = up.core.Audio.init(std.heap.wasm_allocator, .{ .availability = .blocked }) catch return -10;
    defer blocked.deinit();
    const blocked_music = blocked.loadMusic(tone_ogg, .{}) catch return -11;
    if (blocked.playMusic(blocked_music, .{})) |_| return -12 else |err| {
        if (err != error.AudioUnavailable) return -13;
    }
    return 0;
}
