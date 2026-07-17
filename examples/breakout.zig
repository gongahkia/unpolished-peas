const std = @import("std");
const up = @import("unpolished-peas");
const breakout = @import("breakout_game.zig");
const atlas_data = @import("programmatic_atlas.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var assets = try up.assets.AssetStore.initExecutable(allocator);
    defer assets.deinit();
    const ball = try assets.loadImage("ball.png");
    const sound = try assets.loadSound("blip.wav");
    var audio = try up.assets.AudioMixer.init(allocator, .{});
    defer audio.deinit();
    var samples: [128]up.assets.AudioSample = undefined;
    var canvas = try up.graphics.Canvas.init(allocator, breakout.width, breakout.height);
    defer canvas.deinit();
    var game = breakout.Game{};
    var atlas = try atlas_data.ballAtlas(allocator, try assets.tryImage(ball));
    defer atlas.deinit();
    const ball_frame = atlas.findFrame("tile_a") orelse return error.MissingAtlasFrame;

    var frame: u32 = 0;
    while (frame < 360) : (frame += 1) {
        const axis: f32 = if ((frame / 90) % 2 == 0) 1 else -1;
        const event = game.step(1.0 / 60.0, axis);
        if (event.brick or event.paddle) _ = try audio.playSound(try assets.trySoundPtr(sound), .{ .volume = 0.2 });
        try audio.mix(&samples);
    }
    game.drawHeadlessAtlas(&canvas, atlas, ball_frame);
    try std.fs.cwd().makePath("zig-out");
    try canvas.writePpmFile("zig-out/breakout.ppm");
}
