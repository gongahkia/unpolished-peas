const std = @import("std");
const atlas_mod = @import("atlas.zig");
const Color = @import("color.zig").Color;
const Image = @import("image.zig").Image;
const font = @import("font.zig");
const Vec2 = @import("math.zig").Vec2;
const text_layout = @import("text_layout.zig");

pub const ClipRect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub fn contains(self: ClipRect, x: i32, y: i32) bool {
        return x >= self.x and y >= self.y and x < self.x + self.w and y < self.y + self.h;
    }
};

pub const BlendMode = enum { alpha, additive };

pub const Sprite = struct {
    width: u32,
    height: u32,
    pixels: []const Color,

    pub fn get(self: Sprite, x: u32, y: u32) Color {
        std.debug.assert(x < self.width);
        std.debug.assert(y < self.height);
        return self.pixels[@as(usize, y) * self.width + x];
    }
};

pub const Canvas = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    pixels: []Color,
    clip: ?ClipRect = null,
    blend: BlendMode = .alpha,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !Canvas {
        if (width == 0 or height == 0) return error.InvalidCanvasSize;
        const count = std.math.mul(usize, width, height) catch return error.CanvasTooLarge;
        const pixels = try allocator.alloc(Color, count);
        @memset(pixels, Color.transparent);
        return .{ .allocator = allocator, .width = width, .height = height, .pixels = pixels };
    }

    pub fn deinit(self: *Canvas) void {
        self.allocator.free(self.pixels);
        self.* = undefined;
    }

    pub fn clear(self: *Canvas, color: Color) void {
        @memset(self.pixels, color);
    }

    pub fn pushClip(self: *Canvas, next: ClipRect) ?ClipRect {
        const previous = self.clip;
        self.clip = if (previous) |current| intersectClip(current, next) else next;
        return previous;
    }

    pub fn restoreClip(self: *Canvas, previous: ?ClipRect) void {
        self.clip = previous;
    }

    pub fn setBlend(self: *Canvas, blend: BlendMode) BlendMode {
        const previous = self.blend;
        self.blend = blend;
        return previous;
    }

    pub fn pixel(self: *Canvas, x: i32, y: i32, color: Color) void {
        if (self.index(x, y)) |i| {
            self.pixels[i] = switch (self.blend) {
                .alpha => color.over(self.pixels[i]),
                .additive => color.add(self.pixels[i]),
            };
        }
    }

    pub fn get(self: Canvas, x: i32, y: i32) ?Color {
        if (self.index(x, y)) |i| return self.pixels[i];
        return null;
    }

    pub fn fillRect(self: *Canvas, x: i32, y: i32, w: i32, h: i32, color: Color) void {
        if (w <= 0 or h <= 0) return;
        const width_i: i32 = @intCast(self.width);
        const height_i: i32 = @intCast(self.height);
        const x0 = @max(0, x);
        const y0 = @max(0, y);
        const x1 = @min(width_i, x + w);
        const y1 = @min(height_i, y + h);
        if (x0 >= x1 or y0 >= y1) return;

        var py = y0;
        while (py < y1) : (py += 1) {
            var px = x0;
            while (px < x1) : (px += 1) self.pixel(px, py, color);
        }
    }

    pub fn strokeRect(self: *Canvas, x: i32, y: i32, w: i32, h: i32, color: Color) void {
        self.fillRect(x, y, w, 1, color);
        self.fillRect(x, y + h - 1, w, 1, color);
        self.fillRect(x, y, 1, h, color);
        self.fillRect(x + w - 1, y, 1, h, color);
    }

    pub fn fillCircle(self: *Canvas, cx: i32, cy: i32, radius: i32, color: Color) void {
        if (radius <= 0) return;
        const r2 = radius * radius;
        var y = -radius;
        while (y <= radius) : (y += 1) {
            var x = -radius;
            while (x <= radius) : (x += 1) {
                if (x * x + y * y <= r2) self.pixel(cx + x, cy + y, color);
            }
        }
    }

    pub fn fillTriangle(self: *Canvas, a: Vec2, b: Vec2, c: Vec2, color: Color) void {
        self.fillTriangleImpl(a, b, c, color, false);
    }

    pub fn fillQuad(self: *Canvas, a: Vec2, b: Vec2, c: Vec2, d: Vec2, color: Color) void {
        self.fillTriangleImpl(a, b, c, color, false);
        self.fillTriangleImpl(a, c, d, color, true);
    }

    fn fillTriangleImpl(self: *Canvas, a: Vec2, b: Vec2, c: Vec2, color: Color, exclude_first_edge: bool) void {
        const area = edge(a, b, c);
        if (area == 0) return;
        const width_i: i32 = @intCast(self.width);
        const height_i: i32 = @intCast(self.height);
        const min_x: i32 = @max(0, @as(i32, @intFromFloat(@floor(@min(a.x, @min(b.x, c.x))))));
        const min_y: i32 = @max(0, @as(i32, @intFromFloat(@floor(@min(a.y, @min(b.y, c.y))))));
        const max_x: i32 = @min(width_i - 1, @as(i32, @intFromFloat(@ceil(@max(a.x, @max(b.x, c.x))))));
        const max_y: i32 = @min(height_i - 1, @as(i32, @intFromFloat(@ceil(@max(a.y, @max(b.y, c.y))))));
        if (min_x > max_x or min_y > max_y) return;

        var y = min_y;
        while (y <= max_y) : (y += 1) {
            var x = min_x;
            while (x <= max_x) : (x += 1) {
                const point = Vec2.init(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5);
                const ab = edge(a, b, point);
                const bc = edge(b, c, point);
                const ca = edge(c, a, point);
                const first_edge = if (exclude_first_edge) if (area > 0) ab > 0 else ab < 0 else if (area > 0) ab >= 0 else ab <= 0;
                if (first_edge and ((area > 0 and bc >= 0 and ca >= 0) or (area < 0 and bc <= 0 and ca <= 0))) {
                    self.pixel(x, y, color);
                }
            }
        }
    }

    pub fn line(self: *Canvas, x0_in: i32, y0_in: i32, x1_in: i32, y1_in: i32, color: Color) void {
        var x0 = x0_in;
        var y0 = y0_in;
        const x1 = x1_in;
        const y1 = y1_in;
        const dx: i32 = @intCast(@abs(x1 - x0));
        const sx: i32 = if (x0 < x1) 1 else -1;
        const dy: i32 = -@as(i32, @intCast(@abs(y1 - y0)));
        const sy: i32 = if (y0 < y1) 1 else -1;
        var err = dx + dy;

        while (true) {
            self.pixel(x0, y0, color);
            if (x0 == x1 and y0 == y1) break;
            const e2 = 2 * err;
            if (e2 >= dy) {
                err += dy;
                x0 += sx;
            }
            if (e2 <= dx) {
                err += dx;
                y0 += sy;
            }
        }
    }

    pub fn drawSprite(self: *Canvas, sprite: Sprite, dst_x: i32, dst_y: i32) void {
        var y: u32 = 0;
        while (y < sprite.height) : (y += 1) {
            var x: u32 = 0;
            while (x < sprite.width) : (x += 1) {
                self.pixel(dst_x + @as(i32, @intCast(x)), dst_y + @as(i32, @intCast(y)), sprite.get(x, y));
            }
        }
    }

    pub fn drawImage(self: *Canvas, image: Image, dst_x: i32, dst_y: i32) void {
        self.drawSprite(image.sprite(), dst_x, dst_y);
    }

    pub fn drawAtlasFrame(self: *Canvas, atlas: atlas_mod.Atlas, handle: atlas_mod.AtlasFrameHandle, dst_x: i32, dst_y: i32, options: atlas_mod.DrawSpriteOptions) void {
        if (options.scale == 0) return;
        const frame = atlas.frame(handle);
        const scale: i32 = @intCast(options.scale);
        const origin_x = switch (options.origin) {
            .top_left => dst_x,
            .center => dst_x - @divTrunc(frame.source_w * scale, 2),
        };
        const origin_y = switch (options.origin) {
            .top_left => dst_y,
            .center => dst_y - @divTrunc(frame.source_h * scale, 2),
        };
        const trim_w = if (frame.rotated) frame.h else frame.w;
        const trim_h = if (frame.rotated) frame.w else frame.h;
        var local_y: i32 = 0;
        while (local_y < trim_h) : (local_y += 1) {
            var local_x: i32 = 0;
            while (local_x < trim_w) : (local_x += 1) {
                const source_x = if (frame.rotated) frame.x + local_y else frame.x + local_x;
                const source_y = if (frame.rotated) frame.y + frame.h - 1 - local_x else frame.y + local_y;
                if (source_x < 0 or source_y < 0) continue;
                const sx: u32 = @intCast(source_x);
                const sy: u32 = @intCast(source_y);
                if (sx >= atlas.image.width or sy >= atlas.image.height) continue;
                var logical_x = frame.offset_x + local_x;
                var logical_y = frame.offset_y + local_y;
                if (options.flip_x) logical_x = frame.source_w - 1 - logical_x;
                if (options.flip_y) logical_y = frame.source_h - 1 - logical_y;
                const pixel_color = tint(atlas.image.pixels[@as(usize, sy) * atlas.image.width + sx], options.tint);
                const x = origin_x + logical_x * scale;
                const y = origin_y + logical_y * scale;
                if (options.rotation == 0) {
                    self.fillRect(x, y, scale, scale, pixel_color);
                } else {
                    const center = Vec2.init(@as(f32, @floatFromInt(origin_x)) + @as(f32, @floatFromInt(frame.source_w * scale)) / 2, @as(f32, @floatFromInt(origin_y)) + @as(f32, @floatFromInt(frame.source_h * scale)) / 2);
                    self.fillQuad(rotatePoint(.{ .x = @floatFromInt(x), .y = @floatFromInt(y) }, center, options.rotation), rotatePoint(.{ .x = @floatFromInt(x + scale), .y = @floatFromInt(y) }, center, options.rotation), rotatePoint(.{ .x = @floatFromInt(x + scale), .y = @floatFromInt(y + scale) }, center, options.rotation), rotatePoint(.{ .x = @floatFromInt(x), .y = @floatFromInt(y + scale) }, center, options.rotation), pixel_color);
                }
            }
        }
    }

    pub fn drawText(self: *Canvas, text: []const u8, x: i32, y: i32, color: Color) void {
        var laid_out = text_layout.layout(self.allocator, text, .{}) catch return;
        defer laid_out.deinit();
        for (laid_out.glyphs) |glyph| {
            if (glyph.codepoint == ' ') continue;
            const codepoint: u8 = if (glyph.codepoint <= 0x7f) @intCast(glyph.codepoint) else '?';
            self.drawGlyph(codepoint, x + glyph.x, y + glyph.y, color);
        }
    }

    fn drawGlyph(self: *Canvas, c: u8, x: i32, y: i32, color: Color) void {
        const glyph = font.glyph(c);
        var row: usize = 0;
        while (row < font.height) : (row += 1) {
            var col: usize = 0;
            while (col < font.width) : (col += 1) {
                const shift: u3 = @intCast(font.width - 1 - col);
                if (((glyph[row] >> shift) & 1) != 0) {
                    self.pixel(x + @as(i32, @intCast(col)), y + @as(i32, @intCast(row)), color);
                }
            }
        }
    }

    pub fn writePpmFile(self: Canvas, path: []const u8) !void {
        var file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        var buffer: [8192]u8 = undefined;
        var writer = file.writer(&buffer);
        const out = &writer.interface;

        try out.print("P6\n{} {}\n255\n", .{ self.width, self.height });
        for (self.pixels) |p| try out.writeAll(&.{ p.r, p.g, p.b });
        try out.flush();
    }

    fn index(self: Canvas, x: i32, y: i32) ?usize {
        if (x < 0 or y < 0) return null;
        if (self.clip) |clip| if (!clip.contains(x, y)) return null;
        const ux: u32 = @intCast(x);
        const uy: u32 = @intCast(y);
        if (ux >= self.width or uy >= self.height) return null;
        return @as(usize, uy) * self.width + ux;
    }
};

fn edge(a: Vec2, b: Vec2, point: Vec2) f32 {
    return (point.x - a.x) * (b.y - a.y) - (point.y - a.y) * (b.x - a.x);
}

fn rotatePoint(point: Vec2, center: Vec2, angle: f32) Vec2 {
    const sin = @sin(angle);
    const cos = @cos(angle);
    const x = point.x - center.x;
    const y = point.y - center.y;
    return .{ .x = center.x + x * cos - y * sin, .y = center.y + x * sin + y * cos };
}

fn intersectClip(a: ClipRect, b: ClipRect) ClipRect {
    const x = @max(a.x, b.x);
    const y = @max(a.y, b.y);
    const right = @min(a.x + a.w, b.x + b.w);
    const bottom = @min(a.y + a.h, b.y + b.h);
    return .{ .x = x, .y = y, .w = @max(0, right - x), .h = @max(0, bottom - y) };
}

fn tint(color: Color, value: Color) Color {
    return .{
        .r = @intCast((@as(u16, color.r) * value.r) / 255),
        .g = @intCast((@as(u16, color.g) * value.g) / 255),
        .b = @intCast((@as(u16, color.b) * value.b) / 255),
        .a = @intCast((@as(u16, color.a) * value.a) / 255),
    };
}

test "canvas clips draws" {
    var canvas = try Canvas.init(std.testing.allocator, 4, 4);
    defer canvas.deinit();

    canvas.clear(Color.black);
    canvas.fillRect(-1, -1, 3, 3, Color.white);
    try std.testing.expectEqual(Color.white, canvas.get(0, 0).?);
    try std.testing.expectEqual(Color.black, canvas.get(3, 3).?);
}

test "canvas clips affine draws" {
    var canvas = try Canvas.init(std.testing.allocator, 8, 8);
    defer canvas.deinit();

    canvas.clear(Color.black);
    const previous = canvas.pushClip(.{ .x = 2, .y = 2, .w = 3, .h = 3 });
    canvas.fillTriangle(.{ .x = 0, .y = 0 }, .{ .x = 7, .y = 0 }, .{ .x = 0, .y = 7 }, Color.white);
    canvas.restoreClip(previous);
    try std.testing.expectEqual(Color.black, canvas.get(1, 1).?);
    try std.testing.expectEqual(Color.white, canvas.get(2, 2).?);
}

test "sprite draw honors alpha" {
    var canvas = try Canvas.init(std.testing.allocator, 2, 1);
    defer canvas.deinit();

    const pixels = [_]Color{ Color.rgb(255, 0, 0), Color.transparent };
    canvas.clear(Color.black);
    canvas.drawSprite(.{ .width = 2, .height = 1, .pixels = &pixels }, 0, 0);
    try std.testing.expectEqual(Color.rgb(255, 0, 0), canvas.get(0, 0).?);
    try std.testing.expectEqual(Color.black, canvas.get(1, 0).?);
}

test "image draw uses sprite path" {
    var canvas = try Canvas.init(std.testing.allocator, 2, 1);
    defer canvas.deinit();

    const pixels = try std.testing.allocator.dupe(Color, &.{ Color.white, Color.transparent });
    var image = Image{ .allocator = std.testing.allocator, .width = 2, .height = 1, .pixels = pixels };
    defer image.deinit();

    canvas.clear(Color.black);
    canvas.drawImage(image, 0, 0);
    try std.testing.expectEqual(Color.white, canvas.get(0, 0).?);
    try std.testing.expectEqual(Color.black, canvas.get(1, 0).?);
}

test "text draws visible pixels" {
    var canvas = try Canvas.init(std.testing.allocator, 16, 8);
    defer canvas.deinit();

    canvas.clear(Color.black);
    canvas.drawText("A", 0, 0, Color.white);
    try std.testing.expectEqual(Color.white, canvas.get(1, 0).?);
    try std.testing.expectEqual(Color.black, canvas.get(0, 0).?);
}

test "atlas frame draw handles trim rotation flip and tint" {
    var canvas = try Canvas.init(std.testing.allocator, 4, 4);
    defer canvas.deinit();
    const pixels = try std.testing.allocator.dupe(Color, &.{
        Color.rgb(255, 0, 0), Color.rgb(0, 255, 0),
        Color.rgb(0, 0, 255), Color.rgb(255, 255, 255),
    });
    const image = Image{ .allocator = std.testing.allocator, .width = 2, .height = 2, .pixels = pixels };
    const frame_name = try std.testing.allocator.dupe(u8, "rot");
    const path = try std.testing.allocator.dupe(u8, "memory.png");
    const frames = try std.testing.allocator.dupe(atlas_mod.AtlasFrame, &.{.{
        .name = frame_name,
        .x = 0,
        .y = 0,
        .w = 2,
        .h = 2,
        .source_w = 4,
        .source_h = 4,
        .offset_x = 1,
        .offset_y = 1,
        .rotated = true,
    }});
    const animations = try std.testing.allocator.alloc(atlas_mod.Animation, 0);
    var atlas = atlas_mod.Atlas{ .allocator = std.testing.allocator, .image = image, .image_path = path, .frames = frames, .animations = animations };
    defer atlas.deinit();

    canvas.clear(Color.black);
    canvas.drawAtlasFrame(atlas, .{ .index = 0 }, 0, 0, .{ .tint = Color.rgb(255, 128, 255) });
    try std.testing.expectEqual(Color.rgb(0, 128, 0), canvas.get(2, 2).?);
    try std.testing.expectEqual(Color.rgb(255, 0, 0), canvas.get(2, 1).?);
    try std.testing.expectEqual(Color.black, canvas.get(0, 0).?);
}
