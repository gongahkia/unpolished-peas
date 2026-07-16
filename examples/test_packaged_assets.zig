const std = @import("std");
const up = @import("unpolished-peas");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var assets = try up.AssetStore.initExecutable(allocator);
    defer assets.deinit();

    const image = try assets.tryImage(try assets.loadImage("ball.png"));
    if (image.width == 0 or image.height == 0) return error.InvalidRawImage;
    _ = try assets.loadFont("fonts/Basic-Regular.ttf", .{});
    _ = try assets.loadFont("fonts/bitmap.fnt", .{});

    const sound = try assets.trySound(try assets.loadSound("blip.wav"));
    if (sound.frames.len == 0) return error.InvalidRawAudio;

    const ogg_path = try assets.assetPath(allocator, "tone.ogg");
    defer allocator.free(ogg_path);
    var music = try up.Music.openOgg(allocator, ogg_path);
    defer music.deinit();
}
