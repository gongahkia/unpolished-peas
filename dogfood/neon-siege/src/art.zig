const std = @import("std");
const up = @import("unpolished-peas");
const embedded_assets = @import("neon-siege-assets");

/// Ordinary authored assets embedded directly by the game. Both paths are
/// compiled into native and browser builds, so no runtime asset directory or
/// browser fetch is required.
pub const sprite_sheet_png = embedded_assets.sprite_sheet_png;
pub const ui_font_ttf = embedded_assets.ui_font_ttf;

pub const frames = [_]up.assets.AtlasFrameSpec{
    .{ .name = "player", .x = 0, .y = 0, .w = 8, .h = 8 },
    .{ .name = "enemy", .x = 8, .y = 0, .w = 8, .h = 8 },
    .{ .name = "projectile", .x = 0, .y = 8, .w = 8, .h = 8 },
    .{ .name = "pickup", .x = 8, .y = 8, .w = 8, .h = 8 },
};

test "the authored embedded PNG decodes with a stable shape" {
    var image = try up.assets.Image.decode(std.testing.allocator, sprite_sheet_png, .{});
    defer image.deinit();
    try std.testing.expectEqual(@as(u32, 16), image.width);
    try std.testing.expectEqual(@as(u32, 16), image.height);
    try std.testing.expectEqual(up.core.Color.rgba(0, 0, 0, 0), image.pixels[0]);
    try std.testing.expectEqual(up.core.Color.rgba(255, 198, 74, 255), image.pixels[8 + 8 * image.width]);
    var canvas = try up.graphics.Canvas.init(std.testing.allocator, image.width, image.height);
    defer canvas.deinit();
    canvas.drawImage(image, 0, 0);
    try std.testing.expectEqual(image.pixels[8 + 8 * image.width], canvas.get(8, 8).?);
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
