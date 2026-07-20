const std = @import("std");
const Color = @import("color.zig").Color;
const Sprite = @import("canvas.zig").Sprite;

const c = @cImport({
    @cInclude("stb_image.h");
});

pub const DecodeOptions = struct {
    max_input_bytes: usize = 32 * 1024 * 1024,
    max_width: u32 = 4096,
    max_height: u32 = 4096,
    max_pixels: u64 = 4096 * 4096,
};

pub const Format = enum { png, jpeg, tga };

pub const Image = struct { // owns decoded pixels allocated by decode; call deinit once after borrowed sprites are unused.
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    pixels: []Color,

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, options: DecodeOptions) !Image {
        if (bytes.len == 0) return error.InvalidImage;
        if (bytes.len > options.max_input_bytes or bytes.len > std.math.maxInt(c_int)) return error.ImageInputTooLarge;
        _ = try detectFormat(bytes);

        var w: c_int = 0;
        var h: c_int = 0;
        var channels: c_int = 0;
        if (c.stbi_info_from_memory(bytes.ptr, @intCast(bytes.len), &w, &h, &channels) == 0) return error.InvalidImage;

        if (w <= 0 or h <= 0) return error.InvalidImageSize;
        const width: u32 = @intCast(w);
        const height: u32 = @intCast(h);
        if (width > options.max_width or height > options.max_height) return error.ImageTooLarge;
        const count = std.math.mul(u64, width, height) catch return error.ImageTooLarge;
        if (count > options.max_pixels or count > std.math.maxInt(usize)) return error.ImageTooLarge;

        const raw = c.stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &w, &h, &channels, 4) orelse return error.InvalidImage;
        defer c.stbi_image_free(raw);

        const pixels = try allocator.alloc(Color, @intCast(count));
        errdefer allocator.free(pixels);

        const src: [*]const u8 = @ptrCast(raw);
        var i: usize = 0;
        while (i < pixels.len) : (i += 1) {
            const base = i * 4;
            pixels[i] = .{
                .r = src[base],
                .g = src[base + 1],
                .b = src[base + 2],
                .a = src[base + 3],
            };
        }

        return .{ .allocator = allocator, .width = width, .height = height, .pixels = pixels };
    }

    pub fn decodePng(allocator: std.mem.Allocator, bytes: []const u8) !Image {
        return decode(allocator, bytes, .{});
    }

    pub fn detectFormat(bytes: []const u8) !Format {
        if (isPng(bytes)) return .png;
        if (isJpeg(bytes)) return .jpeg;
        if (isTga(bytes)) return .tga;
        return error.UnsupportedImageFormat;
    }

    pub fn deinit(self: *Image) void {
        self.allocator.free(self.pixels);
        self.* = undefined;
    }

    pub fn clone(self: Image, allocator: std.mem.Allocator) !Image {
        return .{ .allocator = allocator, .width = self.width, .height = self.height, .pixels = try allocator.dupe(Color, self.pixels) };
    }

    pub fn sprite(self: Image) Sprite {
        return .{ .width = self.width, .height = self.height, .pixels = self.pixels };
    }
};

fn isPng(bytes: []const u8) bool {
    return bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], &.{ 137, 80, 78, 71, 13, 10, 26, 10 });
}

fn isJpeg(bytes: []const u8) bool {
    return bytes.len >= 3 and bytes[0] == 0xff and bytes[1] == 0xd8 and bytes[2] == 0xff;
}

fn isTga(bytes: []const u8) bool {
    return bytes.len >= 18 and bytes[1] == 0 and bytes[2] == 2 and (bytes[16] == 24 or bytes[16] == 32);
}

test "decode validates PNG JPEG and TGA fixtures" {
    const png = try std.fs.cwd().readFileAlloc(std.testing.allocator, "examples/assets/ball.png", 1024 * 1024);
    defer std.testing.allocator.free(png);
    var decoded_png = try Image.decode(std.testing.allocator, png, .{});
    defer decoded_png.deinit();
    try std.testing.expect(decoded_png.width > 0 and decoded_png.height > 0);

    const jpeg_base64 = "/9j/4AAQSkZJRgABAQAASABIAAD/4QBMRXhpZgAATU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAAAaADAAQAAAABAAAAAQAAAAD/7QA4UGhvdG9zaG9wIDMuMAA4QklNBAQAAAAAAAA4QklNBCUAAAAAABDUHYzZjwCyBOmACZjs+EJ+/8AAEQgAAQABAwEiAAIRAQMRAf/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKC//EALUQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+v/EAB8BAAMBAQEBAQEBAQEAAAAAAAABAgMEBQYHCAkKC//EALURAAIBAgQEAwQHBQQEAAECdwABAgMRBAUhMQYSQVEHYXETIjKBCBRCkaGxwQkjM1LwFWJy0QoWJDThJfEXGBkaJicoKSo1Njc4OTpDREVGR0hJSlNUVVZXWFlaY2RlZmdoaWpzdHV2d3h5eoKDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uLj5OXm5+jp6vLz9PX29/j5+v/bAEMAAgICAgICAwICAwUDAwMFBgUFBQUGCAYGBgYGCAoICAgICAgKCgoKCgoKCgwMDAwMDA4ODg4ODw8PDw8PDw8PD//bAEMBAgICBAQEBwQEBxALCQsQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEP/dAAQAAf/aAAwDAQACEQMRAD8A/Xiiiiv5LP2A/9k=";
    var jpeg_bytes: [std.base64.standard.Decoder.calcSizeForSlice(jpeg_base64) catch unreachable]u8 = undefined;
    try std.base64.standard.Decoder.decode(&jpeg_bytes, jpeg_base64);
    var decoded_jpeg = try Image.decode(std.testing.allocator, &jpeg_bytes, .{});
    defer decoded_jpeg.deinit();
    try std.testing.expectEqual(@as(u32, 1), decoded_jpeg.width);
    try std.testing.expectEqual(@as(u32, 1), decoded_jpeg.height);

    const tga = [_]u8{ 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 1, 0, 24, 0x20, 0, 0, 255, 0, 255, 0 };
    var decoded_tga = try Image.decode(std.testing.allocator, &tga, .{});
    defer decoded_tga.deinit();
    try std.testing.expectEqual(@as(u32, 2), decoded_tga.width);
    try std.testing.expectEqual(Color.rgb(255, 0, 0), decoded_tga.pixels[0]);
    try std.testing.expectEqual(Color.rgb(0, 255, 0), decoded_tga.pixels[1]);
}

test "decode rejects malformed and oversized image inputs" {
    try std.testing.expectError(error.UnsupportedImageFormat, Image.decode(std.testing.allocator, "not an image", .{}));
    try std.testing.expectError(error.ImageInputTooLarge, Image.decode(std.testing.allocator, "1234", .{ .max_input_bytes = 3 }));
    const oversized_tga = [_]u8{ 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0x10, 1, 0, 24, 0x20 };
    try std.testing.expectError(error.ImageTooLarge, Image.decode(std.testing.allocator, &oversized_tga, .{}));
}

test "decode admits only the stable PNG JPEG and TGA formats" {
    try std.testing.expectEqual(Format.png, try Image.detectFormat(&.{ 137, 80, 78, 71, 13, 10, 26, 10 }));
    try std.testing.expectEqual(Format.jpeg, try Image.detectFormat(&.{ 0xff, 0xd8, 0xff }));
    try std.testing.expectEqual(Format.tga, try Image.detectFormat(&.{ 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 24, 0 }));
    try std.testing.expectError(error.UnsupportedImageFormat, Image.detectFormat(&.{ 'B', 'M', 0, 0 }));
}
