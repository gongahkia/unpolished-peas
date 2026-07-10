const std = @import("std");
const Color = @import("color.zig").Color;
const Sprite = @import("canvas.zig").Sprite;

const c = @cImport({
    @cInclude("stb_image.h");
});

const max_pixels = 4096 * 4096;

pub const Image = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    pixels: []Color,

    pub fn decodePng(allocator: std.mem.Allocator, bytes: []const u8) !Image {
        var w: c_int = 0;
        var h: c_int = 0;
        var channels: c_int = 0;
        const raw = c.stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &w, &h, &channels, 4) orelse return error.InvalidPng;
        defer c.stbi_image_free(raw);

        if (w <= 0 or h <= 0) return error.InvalidImageSize;
        const width: u32 = @intCast(w);
        const height: u32 = @intCast(h);
        const count = std.math.mul(u32, width, height) catch return error.ImageTooLarge;
        if (count > max_pixels) return error.ImageTooLarge;

        const pixels = try allocator.alloc(Color, count);
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

    pub fn deinit(self: *Image) void {
        self.allocator.free(self.pixels);
        self.* = undefined;
    }

    pub fn sprite(self: Image) Sprite {
        return .{ .width = self.width, .height = self.height, .pixels = self.pixels };
    }
};
