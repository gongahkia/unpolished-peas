const std = @import("std");
const atlas_mod = @import("atlas.zig");
const camera_mod = @import("camera.zig");
const canvas_mod = @import("canvas.zig");
const Color = @import("color.zig").Color;
const font = @import("font.zig");
const Image = @import("image.zig").Image;
const Vec2 = @import("math.zig").Vec2;
const Rect = @import("math.zig").Rect;

pub const CameraCanvas = struct {
    canvas: *canvas_mod.Canvas,
    camera: *const camera_mod.Camera2D,
    canvas_size: Vec2,

    pub fn init(canvas: *canvas_mod.Canvas, camera: *const camera_mod.Camera2D) CameraCanvas {
        return .{ .canvas = canvas, .camera = camera, .canvas_size = .{ .x = @floatFromInt(canvas.width), .y = @floatFromInt(canvas.height) } };
    }

    pub fn pixel(self: CameraCanvas, point: Vec2, color: Color) void {
        const previous = self.pushClip();
        defer self.canvas.restoreClip(previous);
        const screen = self.camera.worldToCanvas(point, self.canvas_size);
        self.canvas.pixel(roundToI32(screen.x), roundToI32(screen.y), color);
    }

    pub fn line(self: CameraCanvas, from: Vec2, to: Vec2, color: Color) void {
        const previous = self.pushClip();
        defer self.canvas.restoreClip(previous);
        const a = self.camera.worldToCanvas(from, self.canvas_size);
        const b = self.camera.worldToCanvas(to, self.canvas_size);
        self.canvas.line(roundToI32(a.x), roundToI32(a.y), roundToI32(b.x), roundToI32(b.y), color);
    }

    pub fn fillRect(self: CameraCanvas, rect: Rect, color: Color) void {
        if (!self.camera.isVisibleRect(rect, self.canvas_size)) return;
        const previous = self.pushClip();
        defer self.canvas.restoreClip(previous);
        const a = self.camera.worldToCanvas(.{ .x = rect.x, .y = rect.y }, self.canvas_size);
        const b = self.camera.worldToCanvas(.{ .x = rect.x + rect.w, .y = rect.y }, self.canvas_size);
        const c = self.camera.worldToCanvas(.{ .x = rect.x + rect.w, .y = rect.y + rect.h }, self.canvas_size);
        const d = self.camera.worldToCanvas(.{ .x = rect.x, .y = rect.y + rect.h }, self.canvas_size);
        self.canvas.fillQuad(a, b, c, d, color);
    }

    pub fn strokeRect(self: CameraCanvas, rect: Rect, color: Color) void {
        if (!self.camera.isVisibleRect(rect, self.canvas_size)) return;
        self.line(.{ .x = rect.x, .y = rect.y }, .{ .x = rect.x + rect.w, .y = rect.y }, color);
        self.line(.{ .x = rect.x + rect.w, .y = rect.y }, .{ .x = rect.x + rect.w, .y = rect.y + rect.h }, color);
        self.line(.{ .x = rect.x + rect.w, .y = rect.y + rect.h }, .{ .x = rect.x, .y = rect.y + rect.h }, color);
        self.line(.{ .x = rect.x, .y = rect.y + rect.h }, .{ .x = rect.x, .y = rect.y }, color);
    }

    pub fn fillCircle(self: CameraCanvas, center: Vec2, radius: f32, color: Color) void {
        if (!self.camera.isVisibleRect(.init(center.x - radius, center.y - radius, radius * 2, radius * 2), self.canvas_size)) return;
        const previous = self.pushClip();
        defer self.canvas.restoreClip(previous);
        const screen = self.camera.worldToCanvas(center, self.canvas_size);
        self.canvas.fillCircle(roundToI32(screen.x), roundToI32(screen.y), @max(1, roundToI32(radius * self.camera.zoom)), color);
    }

    pub fn drawImage(self: CameraCanvas, image: Image, position: Vec2) void {
        self.drawImageRect(image, position, .{ .x = @floatFromInt(image.width), .y = @floatFromInt(image.height) });
    }

    pub fn drawAtlasFrame(self: CameraCanvas, atlas: atlas_mod.Atlas, handle: atlas_mod.AtlasFrameHandle, position: Vec2, options: atlas_mod.DrawSpriteOptions) void {
        if (options.scale == 0) return;
        const frame = atlas.frame(handle);
        const scale: f32 = @floatFromInt(options.scale);
        const origin = switch (options.origin) {
            .top_left => position,
            .center => .{ .x = position.x - @as(f32, @floatFromInt(frame.source_w)) * scale / 2, .y = position.y - @as(f32, @floatFromInt(frame.source_h)) * scale / 2 },
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
                const color = tint(atlas.image.pixels[@as(usize, sy) * atlas.image.width + sx], options.tint);
                if (color.a == 0) continue;
                self.fillRect(.init(origin.x + @as(f32, @floatFromInt(logical_x)) * scale, origin.y + @as(f32, @floatFromInt(logical_y)) * scale, scale, scale), color);
            }
        }
    }

    pub fn drawText(self: CameraCanvas, text: []const u8, position: Vec2, color: Color) void {
        var pen = position;
        for (text) |char| {
            switch (char) {
                '\n' => {
                    pen.x = position.x;
                    pen.y += font.height + 1;
                },
                ' ' => pen.x += font.width + 1,
                else => {
                    const glyph = font.glyph(char);
                    for (glyph, 0..) |row, row_index| {
                        var col: usize = 0;
                        while (col < font.width) : (col += 1) {
                            const shift: u3 = @intCast(font.width - 1 - col);
                            if (((row >> shift) & 1) != 0) self.fillRect(.init(pen.x + @as(f32, @floatFromInt(col)), pen.y + @as(f32, @floatFromInt(row_index)), 1, 1), color);
                        }
                    }
                    pen.x += font.width + 1;
                },
            }
        }
    }

    fn pushClip(self: CameraCanvas) ?canvas_mod.ClipRect {
        const viewport = self.camera.canvasViewport(self.canvas_size);
        return self.canvas.pushClip(.{
            .x = floorToI32(viewport.x),
            .y = floorToI32(viewport.y),
            .w = @max(0, ceilToI32(viewport.w)),
            .h = @max(0, ceilToI32(viewport.h)),
        });
    }

    fn drawImageRect(self: CameraCanvas, image: Image, position: Vec2, size: Vec2) void {
        const rect = Rect.init(position.x, position.y, size.x, size.y);
        if (!self.camera.isVisibleRect(rect, self.canvas_size)) return;
        const previous = self.pushClip();
        defer self.canvas.restoreClip(previous);
        const a = self.camera.worldToCanvas(.{ .x = rect.x, .y = rect.y }, self.canvas_size);
        const b = self.camera.worldToCanvas(.{ .x = rect.x + rect.w, .y = rect.y }, self.canvas_size);
        const c = self.camera.worldToCanvas(.{ .x = rect.x + rect.w, .y = rect.y + rect.h }, self.canvas_size);
        const d = self.camera.worldToCanvas(.{ .x = rect.x, .y = rect.y + rect.h }, self.canvas_size);
        const min_x = @max(0, floorToI32(@min(a.x, @min(b.x, @min(c.x, d.x)))));
        const min_y = @max(0, floorToI32(@min(a.y, @min(b.y, @min(c.y, d.y)))));
        const max_x = @min(@as(i32, @intCast(self.canvas.width)) - 1, ceilToI32(@max(a.x, @max(b.x, @max(c.x, d.x)))));
        const max_y = @min(@as(i32, @intCast(self.canvas.height)) - 1, ceilToI32(@max(a.y, @max(b.y, @max(c.y, d.y)))));
        if (min_x > max_x or min_y > max_y) return;

        var y = min_y;
        while (y <= max_y) : (y += 1) {
            var x = min_x;
            while (x <= max_x) : (x += 1) {
                const world = self.camera.canvasToWorld(.{ .x = @as(f32, @floatFromInt(x)) + 0.5, .y = @as(f32, @floatFromInt(y)) + 0.5 }, self.canvas_size);
                const u = (world.x - position.x) / size.x;
                const v = (world.y - position.y) / size.y;
                if (u < 0 or v < 0 or u >= 1 or v >= 1) continue;
                const color = sampleImage(image, u, v, self.camera.sampling);
                if (color.a != 0) self.canvas.pixel(x, y, color);
            }
        }
    }
};

fn floorToI32(value: f32) i32 {
    return @intFromFloat(@floor(value));
}

fn ceilToI32(value: f32) i32 {
    return @intFromFloat(@ceil(value));
}

fn roundToI32(value: f32) i32 {
    return @intFromFloat(@round(value));
}

fn tint(color: Color, value: Color) Color {
    return .{
        .r = @intCast((@as(u16, color.r) * value.r) / 255),
        .g = @intCast((@as(u16, color.g) * value.g) / 255),
        .b = @intCast((@as(u16, color.b) * value.b) / 255),
        .a = @intCast((@as(u16, color.a) * value.a) / 255),
    };
}

fn sampleImage(image: Image, u: f32, v: f32, sampling: camera_mod.Sampling) Color {
    const x = u * @as(f32, @floatFromInt(image.width)) - 0.5;
    const y = v * @as(f32, @floatFromInt(image.height)) - 0.5;
    return switch (sampling) {
        .nearest => imageColor(image, roundToI32(x), roundToI32(y)),
        .bilinear => blk: {
            const x0 = floorToI32(x);
            const y0 = floorToI32(y);
            const tx = x - @as(f32, @floatFromInt(x0));
            const ty = y - @as(f32, @floatFromInt(y0));
            const top = lerpColor(imageColor(image, x0, y0), imageColor(image, x0 + 1, y0), tx);
            const bottom = lerpColor(imageColor(image, x0, y0 + 1), imageColor(image, x0 + 1, y0 + 1), tx);
            break :blk lerpColor(top, bottom, ty);
        },
    };
}

fn imageColor(image: Image, x: i32, y: i32) Color {
    const max_x: i32 = @intCast(image.width - 1);
    const max_y: i32 = @intCast(image.height - 1);
    const clamped_x: u32 = @intCast(@max(0, @min(max_x, x)));
    const clamped_y: u32 = @intCast(@max(0, @min(max_y, y)));
    return image.pixels[@as(usize, clamped_y) * image.width + clamped_x];
}

fn lerpColor(a: Color, b: Color, t: f32) Color {
    return .{
        .r = @intFromFloat(@round(@as(f32, @floatFromInt(a.r)) + (@as(f32, @floatFromInt(b.r)) - @as(f32, @floatFromInt(a.r))) * t)),
        .g = @intFromFloat(@round(@as(f32, @floatFromInt(a.g)) + (@as(f32, @floatFromInt(b.g)) - @as(f32, @floatFromInt(a.g))) * t)),
        .b = @intFromFloat(@round(@as(f32, @floatFromInt(a.b)) + (@as(f32, @floatFromInt(b.b)) - @as(f32, @floatFromInt(a.b))) * t)),
        .a = @intFromFloat(@round(@as(f32, @floatFromInt(a.a)) + (@as(f32, @floatFromInt(b.a)) - @as(f32, @floatFromInt(a.a))) * t)),
    };
}

test "camera canvas clips to viewport" {
    var canvas = try canvas_mod.Canvas.init(std.testing.allocator, 8, 8);
    defer canvas.deinit();
    canvas.clear(Color.black);
    const camera = camera_mod.Camera2D{ .viewport = .{ .x = 2, .y = 2, .w = 4, .h = 4 } };
    const world = CameraCanvas.init(&canvas, &camera);
    world.fillRect(.init(-8, -8, 16, 16), Color.white);
    try std.testing.expectEqual(Color.black, canvas.get(1, 1).?);
    try std.testing.expectEqual(Color.white, canvas.get(2, 2).?);
}

test "camera canvas rotates world rectangle" {
    var canvas = try canvas_mod.Canvas.init(std.testing.allocator, 16, 16);
    defer canvas.deinit();
    canvas.clear(Color.black);
    const camera = camera_mod.Camera2D{ .position = .{ .x = 8, .y = 8 }, .rotation = @as(f32, std.math.pi) / 2, .pixel_snap = .off };
    const world = CameraCanvas.init(&canvas, &camera);
    world.fillRect(.init(8, 8, 4, 1), Color.white);
    try std.testing.expectEqual(Color.white, canvas.get(8, 5).?);
}
