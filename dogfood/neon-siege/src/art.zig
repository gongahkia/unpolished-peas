const std = @import("std");
const up = @import("unpolished-peas");
const embedded_assets = @import("neon-siege-assets");

/// Ordinary authored assets embedded directly by the game. Both paths are
/// compiled into native and browser builds, so no runtime asset directory or
/// browser fetch is required.
pub const sprite_sheet_png = embedded_assets.sprite_sheet_png;
pub const ui_font_ttf = embedded_assets.ui_font_ttf;
pub const background_music_ogg = embedded_assets.background_music_ogg;

pub const frames = [_]up.assets.AtlasFrameSpec{
    .{ .name = "player-idle", .x = 0, .y = 0, .w = 8, .h = 8 },
    .{ .name = "player-walk", .x = 8, .y = 0, .w = 8, .h = 8 },
    .{ .name = "enemy", .x = 16, .y = 0, .w = 8, .h = 8 },
    .{ .name = "projectile", .x = 24, .y = 0, .w = 8, .h = 8 },
    .{ .name = "pickup", .x = 0, .y = 8, .w = 8, .h = 8 },
};

/// These values are game-owned static data. The public animation helper only
/// selects an existing Atlas frame; position, tint, and all game behavior
/// remain in the game.
pub const player_idle_steps = [_]up.graphics.SpriteAnimationStep{
    .{ .frame = .{ .index = 0 }, .ticks = 1 },
};
pub const player_walk_steps = [_]up.graphics.SpriteAnimationStep{
    .{ .frame = .{ .index = 0 }, .ticks = 6 },
    .{ .frame = .{ .index = 1 }, .ticks = 6 },
};
pub const player_idle_clip = up.graphics.SpriteAnimationClip{ .steps = &player_idle_steps, .mode = .loop };
pub const player_walk_clip = up.graphics.SpriteAnimationClip{ .steps = &player_walk_steps, .mode = .loop };

test "the authored embedded PNG decodes with a stable shape" {
    var image = try up.assets.Image.decode(std.testing.allocator, sprite_sheet_png, .{});
    defer image.deinit();
    try std.testing.expectEqual(@as(u32, 32), image.width);
    try std.testing.expectEqual(@as(u32, 16), image.height);
    try std.testing.expectEqual(up.core.Color.rgba(0, 0, 0, 0), image.pixels[0]);
    try std.testing.expectEqual(up.core.Color.rgba(255, 198, 74, 255), image.pixels[3 + 8 * image.width]);
    var canvas = try up.graphics.Canvas.init(std.testing.allocator, image.width, image.height);
    defer canvas.deinit();
    canvas.drawImage(image, 0, 0);
    try std.testing.expectEqual(image.pixels[3 + 8 * image.width], canvas.get(3, 8).?);
}

test "the authored embedded TrueType font rasterizes basic HUD glyphs" {
    var font = try up.assets.Font.decodeTrueType(std.testing.allocator, ui_font_ttf, .{ .pixel_height = 8, .atlas_width = 128, .atlas_height = 128 });
    defer font.deinit();
    try std.testing.expect(font.glyphForCodepoint('S') != null);
    try std.testing.expect(font.glyphForCodepoint('7') != null);
    var canvas = try up.graphics.Canvas.init(std.testing.allocator, 32, 12);
    defer canvas.deinit();
    canvas.clear(up.core.Color.rgb(2, 3, 5));
    font.drawText(&canvas, "S7", 1, 1, up.core.Color.white);
    try std.testing.expectEqual(@as(u64, 9_566_740_615_137_773_452), up.testSupport.canvasHash(canvas));
}

test "the authored embedded Vorbis loop is a compact incremental music source" {
    var music = try up.assets.Music.decodeOgg(std.testing.allocator, background_music_ogg);
    defer music.deinit();
    var mixer = try up.assets.AudioMixer.init(std.testing.allocator, .{});
    defer mixer.deinit();
    _ = try mixer.playMusic(&music, .{ .loop = true });
    var output: [256]up.assets.AudioSample = undefined;
    try mixer.mix(&output);
    var nonzero = false;
    for (output) |sample| {
        if (sample.left != 0 or sample.right != 0) nonzero = true;
    }
    try std.testing.expect(nonzero);
}
