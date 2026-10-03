const up = @import("unpolished-peas");

/// Repository-authored 16x16, 32-bit TGA sprite sheet.
///
/// Keeping this tiny source asset as bytes lets the dogfood project exercise
/// the public Image.decode + Atlas path on native and browser builds without
/// a checkout-relative runtime file path. Real projects can instead embed or
/// package their own PNG, JPEG, or TGA data.
pub const sprite_sheet_tga = makeSpriteSheet();

pub const frames = [_]up.assets.AtlasFrameSpec{
    .{ .name = "player", .x = 0, .y = 0, .w = 8, .h = 8 },
    .{ .name = "enemy", .x = 8, .y = 0, .w = 8, .h = 8 },
    .{ .name = "projectile", .x = 0, .y = 8, .w = 8, .h = 8 },
    .{ .name = "pickup", .x = 8, .y = 8, .w = 8, .h = 8 },
};

/// Builds an owned image using only the portable public `Image` value shape.
/// Browser builds currently cannot call `Image.decode` because its stb-backed
/// decoder is native-only; the game deliberately keeps the same generated
/// image semantics on every Peas target.
pub fn makeImage(allocator: std.mem.Allocator) !up.assets.Image {
    const pixels = try allocator.alloc(up.core.Color, 16 * 16);
    for (0..16) |y| for (0..16) |x| {
        const rgba = pixel(x, y);
        pixels[y * 16 + x] = .{ .r = rgba[0], .g = rgba[1], .b = rgba[2], .a = rgba[3] };
    };
    return .{ .allocator = allocator, .width = 16, .height = 16, .pixels = pixels };
}

fn makeSpriteSheet() [18 + 16 * 16 * 4]u8 {
    var bytes = [_]u8{0} ** (18 + 16 * 16 * 4);
    // Uncompressed true-colour TGA, top-left origin, BGRA pixels.
    bytes[2] = 2;
    bytes[12] = 16;
    bytes[14] = 16;
    bytes[16] = 32;
    bytes[17] = 0x28;

    for (0..16) |y| for (0..16) |x| {
        const rgba = pixel(x, y);
        const base = 18 + (y * 16 + x) * 4;
        bytes[base] = rgba[2];
        bytes[base + 1] = rgba[1];
        bytes[base + 2] = rgba[0];
        bytes[base + 3] = rgba[3];
    };
    return bytes;
}

fn pixel(x: usize, y: usize) [4]u8 {
    const local_x = x % 8;
    const local_y = y % 8;
    const inside = local_x >= 1 and local_x <= 6 and local_y >= 1 and local_y <= 6;
    if (!inside) return .{ 0, 0, 0, 0 };

    if (x < 8 and y < 8) return if (local_x == 3 or local_x == 4 or local_y == 3 or local_y == 4) .{ 225, 248, 255, 255 } else .{ 70, 200, 255, 255 };
    if (x >= 8 and y < 8) return if (local_x == 2 or local_x == 5) .{ 255, 219, 236, 255 } else .{ 242, 71, 132, 255 };
    if (x < 8 and y >= 8) return if (local_x >= 3 and local_x <= 4 and local_y >= 2 and local_y <= 5) .{ 255, 232, 132, 255 } else .{ 255, 133, 45, 255 };
    return if (local_x == 3 or local_x == 4 or local_y == 3 or local_y == 4) .{ 236, 255, 184, 255 } else .{ 107, 225, 95, 255 };
}

const std = @import("std");

test "the authored TGA decodes on native hosts" {
    var image = try up.assets.Image.decode(std.testing.allocator, &sprite_sheet_tga, .{});
    defer image.deinit();
    try std.testing.expectEqual(@as(u32, 16), image.width);
    try std.testing.expectEqual(@as(u32, 16), image.height);
}
