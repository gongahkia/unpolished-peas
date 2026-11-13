const std = @import("std");

pub const Color = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,

    pub const black: Color = .{ .r = 0, .g = 0, .b = 0 };
    pub const white: Color = .{ .r = 255, .g = 255, .b = 255 };
    pub const transparent: Color = .{ .a = 0 };

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b };
    }

    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub fn over(src: Color, dst: Color) Color {
        if (src.a == 255) return src;
        if (src.a == 0) return dst;

        const a = @as(u16, src.a);
        const inv = 255 - a;
        return .{
            .r = @intCast((@as(u16, src.r) * a + @as(u16, dst.r) * inv) / 255),
            .g = @intCast((@as(u16, src.g) * a + @as(u16, dst.g) * inv) / 255),
            .b = @intCast((@as(u16, src.b) * a + @as(u16, dst.b) * inv) / 255),
            .a = 255,
        };
    }

    pub fn add(src: Color, dst: Color) Color {
        const alpha = @as(u16, src.a);
        return .{
            .r = @intCast(@min(255, @as(u16, dst.r) + (@as(u16, src.r) * alpha) / 255)),
            .g = @intCast(@min(255, @as(u16, dst.g) + (@as(u16, src.g) * alpha) / 255)),
            .b = @intCast(@min(255, @as(u16, dst.b) + (@as(u16, src.b) * alpha) / 255)),
            .a = 255,
        };
    }
};

test "alpha composite" {
    try std.testing.expectEqual(Color.rgb(255, 0, 0), Color.rgb(255, 0, 0).over(Color.black));
    try std.testing.expectEqual(Color.black, Color.transparent.over(Color.black));
}

test "additive composite" {
    try std.testing.expectEqual(Color.rgb(128, 0, 128), Color.rgba(0, 0, 255, 128).add(Color.rgb(128, 0, 0)));
}
