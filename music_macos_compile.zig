const std = @import("std");
const up = @import("unpolished-peas");

const tone_ogg = @embedFile("examples/assets/tone.ogg");

/// Compile-only target coverage for the portable high-level music path.
pub export fn up_music_macos_compile_smoke() void {
    var audio = up.core.Audio.init(std.heap.page_allocator, .{}) catch return;
    defer audio.deinit();
    const music = audio.loadMusic(tone_ogg, .{}) catch return;
    _ = audio.playMusic(music, .{ .loop = true, .volume = 0.25 }) catch return;
}
