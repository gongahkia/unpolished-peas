const std = @import("std");
const up = @import("unpolished-peas");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var assets = try up.AssetStore.initExecutable(allocator);
    defer assets.deinit();

    _ = try assets.loadImage("ball.png");
    _ = try assets.loadAtlas("atlas.json");
    _ = try assets.loadTileMap("topdown.tmj");
    _ = try assets.loadFont("fonts/Basic-Regular.ttf");
    _ = try assets.loadBitmapFont("fonts/bitmap.fnt");

    const wav_path = try assets.assetPath(allocator, "blip.wav");
    defer allocator.free(wav_path);
    var sound = try up.Sound.loadWav(allocator, wav_path);
    defer sound.deinit();

    const ogg_path = try assets.assetPath(allocator, "tone.ogg");
    defer allocator.free(ogg_path);
    var music = try up.Music.openOgg(allocator, ogg_path);
    defer music.deinit();
}
