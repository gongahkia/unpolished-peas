const std = @import("std");
const up = @import("unpolished-peas");
const breakout = @import("breakout_game.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var assets = try up.AssetStore.initExecutable(allocator);
    defer assets.deinit();
    const ball = try assets.loadPng("ball.png");
    const sound_path = try assets.assetPath(allocator, "blip.wav");
    defer allocator.free(sound_path);
    var sound = try up.Sound.loadWav(allocator, sound_path);
    defer sound.deinit();
    var audio = try up.AudioMixer.init(allocator, .{});
    defer audio.deinit();
    var samples: [128]up.AudioSample = undefined;
    var canvas = try up.Canvas.init(allocator, breakout.width, breakout.height);
    defer canvas.deinit();
    var game = breakout.Game{};

    var frame: u32 = 0;
    while (frame < 360) : (frame += 1) {
        const axis: f32 = if ((frame / 90) % 2 == 0) 1 else -1;
        const event = game.step(1.0 / 60.0, axis);
        if (event.brick or event.paddle) _ = try audio.playSound(&sound, .{ .volume = 0.2 });
        try audio.mix(&samples);
    }
    game.drawHeadless(&canvas, assets.image(ball));
    try std.fs.cwd().makePath("zig-out");
    try canvas.writePpmFile("zig-out/breakout.ppm");
}
