const std = @import("std");
const up = @import("unpolished-peas").api;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var assets = try up.AssetStore.initExecutable(allocator);
    defer assets.deinit();

    _ = try assets.loadImage("ball.png");
    _ = try assets.loadAtlas("atlas.json");
    _ = try assets.loadTileMap("topdown.upmap", .{});
    _ = try assets.loadFont("fonts/Basic-Regular.ttf", .{});
    _ = try assets.loadFont("fonts/bitmap.fnt", .{});

    _ = try assets.loadSound("blip.wav");

    const ogg_path = try assets.assetPath(allocator, "tone.ogg");
    defer allocator.free(ogg_path);
    var music = try up.Music.openOgg(allocator, ogg_path);
    defer music.deinit();
}
