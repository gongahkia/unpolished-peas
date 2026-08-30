const std = @import("std");
const up = @import("unpolished-peas");

const tone_ogg = @embedFile("examples/assets/tone.ogg");

pub export fn up_browser_ogg_decode_smoke() i32 {
    var sound = up.assets.Sound.decodeOgg(std.heap.wasm_allocator, tone_ogg) catch return -1;
    defer sound.deinit();
    if (sound.sample_rate == 0 or sound.frames.len == 0) return -2;
    var music = up.assets.Music.decodeOgg(std.heap.wasm_allocator, tone_ogg) catch return -3;
    defer music.deinit();
    var mixer = up.assets.AudioMixer.init(std.heap.wasm_allocator, .{ .sample_rate = sound.sample_rate }) catch return -4;
    defer mixer.deinit();
    _ = mixer.playMusic(&music, .{}) catch return -5;
    var output: [256]up.assets.AudioSample = undefined;
    mixer.mix(&output) catch return -6;
    for (output) |sample| if (sample.left != 0 or sample.right != 0) return 0;
    return -7;
}
