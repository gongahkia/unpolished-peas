const std = @import("std");
const up = @import("unpolished-peas");
const embedded_assets = @import("lantern-leap-assets");

pub const sprite_sheet_png = embedded_assets.sprite_sheet_png;
pub const ui_font_ttf = embedded_assets.ui_font_ttf;
pub const background_music_ogg = embedded_assets.background_music_ogg;

/// 8x8 frames in `assets/lantern-leap.png`. Clips contain only frame choice
/// and fixed tick durations; the platformer owns every gameplay transition.
pub const frames = [_]up.assets.AtlasFrameSpec{
    .{ .name = "player-idle", .x = 0, .y = 0, .w = 8, .h = 8 },
    .{ .name = "player-run-a", .x = 8, .y = 0, .w = 8, .h = 8 },
    .{ .name = "player-run-b", .x = 16, .y = 0, .w = 8, .h = 8 },
    .{ .name = "player-jump", .x = 24, .y = 0, .w = 8, .h = 8 },
    .{ .name = "glow", .x = 32, .y = 0, .w = 8, .h = 8 },
    .{ .name = "checkpoint", .x = 40, .y = 0, .w = 8, .h = 8 },
    .{ .name = "goal", .x = 48, .y = 0, .w = 8, .h = 8 },
    .{ .name = "spike", .x = 56, .y = 0, .w = 8, .h = 8 },
};

pub const player_idle_steps = [_]up.graphics.SpriteAnimationStep{
    .{ .frame = .{ .index = 0 }, .ticks = 1 },
};
pub const player_run_steps = [_]up.graphics.SpriteAnimationStep{
    .{ .frame = .{ .index = 1 }, .ticks = 5 },
    .{ .frame = .{ .index = 2 }, .ticks = 5 },
};
pub const player_jump_steps = [_]up.graphics.SpriteAnimationStep{
    .{ .frame = .{ .index = 3 }, .ticks = 1 },
};
pub const player_idle_clip = up.graphics.SpriteAnimationClip{ .steps = &player_idle_steps, .mode = .loop };
pub const player_run_clip = up.graphics.SpriteAnimationClip{ .steps = &player_run_steps, .mode = .loop };
pub const player_jump_clip = up.graphics.SpriteAnimationClip{ .steps = &player_jump_steps, .mode = .loop };

test "Lantern Leap's authored PNG and TTF have stable headless output" {
    var image = try up.assets.Image.decode(std.testing.allocator, sprite_sheet_png, .{});
    defer image.deinit();
    try std.testing.expectEqual(@as(u32, 64), image.width);
    try std.testing.expectEqual(@as(u32, 16), image.height);

    var font = try up.assets.Font.decodeTrueType(std.testing.allocator, ui_font_ttf, .{ .pixel_height = 8, .atlas_width = 128, .atlas_height = 128 });
    defer font.deinit();
    try std.testing.expect(font.glyphForCodepoint('L') != null);
    try std.testing.expect(font.glyphForCodepoint('7') != null);
}
