const std = @import("std");
const atlas_mod = @import("atlas.zig");
const canvas_trace = @import("canvas_trace.zig");
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

/// Sampling used when a RenderSurface is scaled during composition.
/// `nearest` is the default because it preserves pixel-art edges exactly.
pub const SurfaceFilter = enum { nearest, linear };

/// Destination geometry and sampling for `Canvas.drawSurface`.
/// Width and height are explicit logical pixels; a zero size is rejected.
pub const SurfaceDrawOptions = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    tint: Color = Color.white,
    filter: SurfaceFilter = .nearest,
};

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

pub const Canvas = struct { // owns its pixel buffer allocated by init; call deinit once.
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    pixels: []Color,
    clip: ?ClipRect = null,
    blend: BlendMode = .alpha,
    // A test-only observer of public logical Canvas operations. Normal
    // rendering leaves this null and does not allocate or hash commands.
    trace: ?*canvas_trace.Trace = null,

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

    /// Attaches a test-owned logical command trace. The Canvas does not own
    /// the trace, which must outlive the attachment.
    pub fn attachTrace(self: *Canvas, trace: *canvas_trace.Trace) void {
        self.trace = trace;
    }

    pub fn detachTrace(self: *Canvas) void {
        self.trace = null;
    }

    pub fn clear(self: *Canvas, color: Color) void {
        if (self.trace) |trace| trace.recordClear(color);
        @memset(self.pixels, color);
    }

    pub fn pushClip(self: *Canvas, next: ClipRect) ?ClipRect {
        const previous = self.clip;
        if (self.trace) |trace| trace.recordPushClip(.{ .x = next.x, .y = next.y, .w = next.w, .h = next.h });
        self.clip = if (previous) |current| intersectClip(current, next) else next;
        return previous;
    }

    pub fn restoreClip(self: *Canvas, previous: ?ClipRect) void {
        if (self.trace) |trace| trace.recordRestoreClip(if (previous) |clip| .{ .x = clip.x, .y = clip.y, .w = clip.w, .h = clip.h } else null);
        self.clip = previous;
    }

    pub fn setBlend(self: *Canvas, blend: BlendMode) BlendMode {
        const previous = self.blend;
        if (self.trace) |trace| trace.recordSetBlend(switch (blend) {
            .alpha => .alpha,
            .additive => .additive,
        });
        self.blend = blend;
        return previous;
    }

    pub fn pixel(self: *Canvas, x: i32, y: i32, color: Color) void {
        if (self.trace) |trace| trace.recordPixel(x, y, color);
        self.blendPixel(x, y, color);
    }

    fn blendPixel(self: *Canvas, x: i32, y: i32, color: Color) void {
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
        if (self.trace) |trace| trace.recordFillRect(x, y, w, h, color);
        self.fillRectImpl(x, y, w, h, color);
    }

    fn fillRectImpl(self: *Canvas, x: i32, y: i32, w: i32, h: i32, color: Color) void {
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
            while (px < x1) : (px += 1) self.blendPixel(px, py, color);
        }
    }

    pub fn strokeRect(self: *Canvas, x: i32, y: i32, w: i32, h: i32, color: Color) void {
        if (self.trace) |trace| trace.recordStrokeRect(x, y, w, h, color);
        self.fillRectImpl(x, y, w, 1, color);
        self.fillRectImpl(x, y + h - 1, w, 1, color);
        self.fillRectImpl(x, y, 1, h, color);
        self.fillRectImpl(x + w - 1, y, 1, h, color);
    }

    pub fn fillCircle(self: *Canvas, cx: i32, cy: i32, radius: i32, color: Color) void {
        if (self.trace) |trace| trace.recordFillCircle(cx, cy, radius, color);
        if (radius <= 0) return;
        const r2 = radius * radius;
        var y = -radius;
        while (y <= radius) : (y += 1) {
            var x = -radius;
            while (x <= radius) : (x += 1) {
                if (x * x + y * y <= r2) self.blendPixel(cx + x, cy + y, color);
            }
        }
    }

    pub fn fillTriangle(self: *Canvas, a: Vec2, b: Vec2, c: Vec2, color: Color) void {
        if (self.trace) |trace| trace.recordFillTriangle(a, b, c, color);
        self.fillTriangleImpl(a, b, c, color, false);
    }

    pub fn fillQuad(self: *Canvas, a: Vec2, b: Vec2, c: Vec2, d: Vec2, color: Color) void {
        if (self.trace) |trace| trace.recordFillQuad(a, b, c, d, color);
        self.fillQuadImpl(a, b, c, d, color);
    }

    fn fillQuadImpl(self: *Canvas, a: Vec2, b: Vec2, c: Vec2, d: Vec2, color: Color) void {
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
                    self.blendPixel(x, y, color);
                }
            }
        }
    }

    pub fn line(self: *Canvas, x0_in: i32, y0_in: i32, x1_in: i32, y1_in: i32, color: Color) void {
        if (self.trace) |trace| trace.recordLine(x0_in, y0_in, x1_in, y1_in, color);
        self.lineImpl(x0_in, y0_in, x1_in, y1_in, color);
    }

    fn lineImpl(self: *Canvas, x0_in: i32, y0_in: i32, x1_in: i32, y1_in: i32, color: Color) void {
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
            self.blendPixel(x0, y0, color);
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
        if (self.trace) |trace| trace.recordSprite(sprite.width, sprite.height, sprite.pixels, dst_x, dst_y);
        self.drawSpriteImpl(sprite, dst_x, dst_y);
    }

    fn drawSpriteImpl(self: *Canvas, sprite: Sprite, dst_x: i32, dst_y: i32) void {
        var y: u32 = 0;
        while (y < sprite.height) : (y += 1) {
            var x: u32 = 0;
            while (x < sprite.width) : (x += 1) {
                self.blendPixel(dst_x + @as(i32, @intCast(x)), dst_y + @as(i32, @intCast(y)), sprite.get(x, y));
            }
        }
    }

    pub fn drawImage(self: *Canvas, image: Image, dst_x: i32, dst_y: i32) void {
        if (self.trace) |trace| trace.recordImage(image.width, image.height, image.pixels, dst_x, dst_y);
        self.drawSpriteImpl(image.sprite(), dst_x, dst_y);
    }

    /// Composites the latest pixels of an owned offscreen RenderSurface. The
    /// source may not be the Canvas currently receiving the draw; doing so is
    /// a feedback loop and returns `error.SurfaceSelfSampling`.
    pub fn drawSurface(self: *Canvas, surface: *const RenderSurface, options: SurfaceDrawOptions) !void {
        if (options.width == 0 or options.height == 0) return error.InvalidSurfaceDrawSize;
        if (options.width > std.math.maxInt(i32) or options.height > std.math.maxInt(i32)) return error.InvalidSurfaceDrawSize;
        if (self == &surface.target) return error.SurfaceSelfSampling;
        if (self.trace) |trace| trace.recordSurface(surface.target.width, surface.target.height, surface.target.pixels, options.x, options.y, options.width, options.height, options.tint, switch (options.filter) {
            .nearest => .nearest,
            .linear => .linear,
        });

        var destination_y: u32 = 0;
        while (destination_y < options.height) : (destination_y += 1) {
            const y_offset: i32 = @intCast(destination_y);
            const y = std.math.add(i32, options.y, y_offset) catch continue;
            var destination_x: u32 = 0;
            while (destination_x < options.width) : (destination_x += 1) {
                const x_offset: i32 = @intCast(destination_x);
                const x = std.math.add(i32, options.x, x_offset) catch continue;
                const source_color = switch (options.filter) {
                    .nearest => sampleSurfaceNearest(&surface.target, destination_x, destination_y, options.width, options.height),
                    .linear => sampleSurfaceLinear(&surface.target, destination_x, destination_y, options.width, options.height),
                };
                self.blendPixel(x, y, tint(source_color, options.tint));
            }
        }
    }

    pub fn drawAtlasFrame(self: *Canvas, atlas: atlas_mod.Atlas, handle: atlas_mod.AtlasFrameHandle, dst_x: i32, dst_y: i32, options: atlas_mod.DrawSpriteOptions) void {
        if (options.scale == 0) return;
        const frame = atlas.frame(handle);
        if (self.trace) |trace| trace.recordAtlasFrame(atlas.image.width, atlas.image.height, atlas.image.pixels, frame, dst_x, dst_y, options);
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
                    self.fillRectImpl(x, y, scale, scale, pixel_color);
                } else {
                    const center = Vec2.init(@as(f32, @floatFromInt(origin_x)) + @as(f32, @floatFromInt(frame.source_w * scale)) / 2, @as(f32, @floatFromInt(origin_y)) + @as(f32, @floatFromInt(frame.source_h * scale)) / 2);
                    self.fillQuadImpl(rotatePoint(.{ .x = @floatFromInt(x), .y = @floatFromInt(y) }, center, options.rotation), rotatePoint(.{ .x = @floatFromInt(x + scale), .y = @floatFromInt(y) }, center, options.rotation), rotatePoint(.{ .x = @floatFromInt(x + scale), .y = @floatFromInt(y + scale) }, center, options.rotation), rotatePoint(.{ .x = @floatFromInt(x), .y = @floatFromInt(y + scale) }, center, options.rotation), pixel_color);
                }
            }
        }
    }

    pub fn drawText(self: *Canvas, text: []const u8, x: i32, y: i32, color: Color) void {
        if (self.trace) |trace| trace.recordText(text, x, y, color);
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
                    self.blendPixel(x + @as(i32, @intCast(col)), y + @as(i32, @intCast(row)), color);
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

    pub fn writePngFile(self: Canvas, path: []const u8) !void {
        var file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        var buffer: [8192]u8 = undefined;
        var writer = file.writer(&buffer);
        try self.writePng(&writer.interface);
        try writer.interface.flush();
    }

    pub fn writePng(self: Canvas, out: *std.Io.Writer) !void {
        const pixel_bytes = std.math.mul(usize, self.width, self.height) catch return error.PngTooLarge;
        const rgba_bytes = std.math.mul(usize, pixel_bytes, 4) catch return error.PngTooLarge;
        const scanline_bytes = std.math.add(usize, std.math.mul(usize, self.width, 4) catch return error.PngTooLarge, 1) catch return error.PngTooLarge;
        const raw_bytes = std.math.mul(usize, scanline_bytes, self.height) catch return error.PngTooLarge;
        if (rgba_bytes != pixel_bytes * @sizeOf(Color)) return error.InvalidPngPixels;

        const raw = try self.allocator.alloc(u8, raw_bytes);
        defer self.allocator.free(raw);
        var raw_index: usize = 0;
        for (self.pixels, 0..) |value, pixel_i| {
            if (pixel_i % self.width == 0) {
                raw[raw_index] = 0;
                raw_index += 1;
            }
            raw[raw_index..][0..4].* = .{ value.r, value.g, value.b, value.a };
            raw_index += 4;
        }

        const compressed = try pngStoredDeflate(self.allocator, raw);
        defer self.allocator.free(compressed);

        try out.writeAll("\x89PNG\r\n\x1a\n");
        var ihdr: [13]u8 = undefined;
        std.mem.writeInt(u32, ihdr[0..4], self.width, .big);
        std.mem.writeInt(u32, ihdr[4..8], self.height, .big);
        ihdr[8..].* = .{ 8, 6, 0, 0, 0 };
        try writePngChunk(out, "IHDR", &ihdr);
        try writePngChunk(out, "IDAT", compressed);
        try writePngChunk(out, "IEND", "");
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

/// Persistent, Peas-owned offscreen 2D surface. It owns a Canvas-sized pixel
/// buffer initialized to transparent black. Draw into `canvas()` with the
/// ordinary Canvas API, then compose it onto another Canvas with
/// `drawSurface`. There is no target stack or GPU-resource ownership exposed.
pub const RenderSurface = struct {
    target: Canvas,

    pub fn init(allocator: std.mem.Allocator, surface_width: u32, surface_height: u32) !RenderSurface {
        if (surface_width == 0 or surface_height == 0 or surface_width > std.math.maxInt(i32) or surface_height > std.math.maxInt(i32)) return error.InvalidRenderSurfaceSize;
        return .{ .target = try Canvas.init(allocator, surface_width, surface_height) };
    }

    pub fn deinit(self: *RenderSurface) void {
        self.target.deinit();
        self.* = undefined;
    }

    /// Borrows the offscreen Canvas. Its contents become visible to later
    /// `drawSurface` calls immediately after ordinary Canvas draw calls return.
    pub fn canvas(self: *RenderSurface) *Canvas {
        return &self.target;
    }

    pub fn width(self: *const RenderSurface) u32 {
        return self.target.width;
    }

    pub fn height(self: *const RenderSurface) u32 {
        return self.target.height;
    }
};

fn sampleSurfaceNearest(source: *const Canvas, destination_x: u32, destination_y: u32, destination_width: u32, destination_height: u32) Color {
    const source_x: u32 = @intCast((@as(u64, destination_x) * source.width) / destination_width);
    const source_y: u32 = @intCast((@as(u64, destination_y) * source.height) / destination_height);
    return source.pixels[@as(usize, source_y) * source.width + source_x];
}

fn sampleSurfaceLinear(source: *const Canvas, destination_x: u32, destination_y: u32, destination_width: u32, destination_height: u32) Color {
    const source_x = ((@as(f32, @floatFromInt(destination_x)) + 0.5) * @as(f32, @floatFromInt(source.width)) / @as(f32, @floatFromInt(destination_width))) - 0.5;
    const source_y = ((@as(f32, @floatFromInt(destination_y)) + 0.5) * @as(f32, @floatFromInt(source.height)) / @as(f32, @floatFromInt(destination_height))) - 0.5;
    const left = std.math.clamp(@as(i32, @intFromFloat(@floor(source_x))), 0, @as(i32, @intCast(source.width - 1)));
    const top = std.math.clamp(@as(i32, @intFromFloat(@floor(source_y))), 0, @as(i32, @intCast(source.height - 1)));
    const right = @min(left + 1, @as(i32, @intCast(source.width - 1)));
    const bottom = @min(top + 1, @as(i32, @intCast(source.height - 1)));
    const horizontal = std.math.clamp(source_x - @as(f32, @floatFromInt(left)), 0, 1);
    const vertical = std.math.clamp(source_y - @as(f32, @floatFromInt(top)), 0, 1);
    const top_color = lerpColor(surfacePixel(source, left, top), surfacePixel(source, right, top), horizontal);
    const bottom_color = lerpColor(surfacePixel(source, left, bottom), surfacePixel(source, right, bottom), horizontal);
    return lerpColor(top_color, bottom_color, vertical);
}

fn surfacePixel(source: *const Canvas, x: i32, y: i32) Color {
    return source.pixels[@as(usize, @intCast(y)) * source.width + @as(usize, @intCast(x))];
}

fn lerpColor(left: Color, right: Color, amount: f32) Color {
    return .{
        .r = lerpChannel(left.r, right.r, amount),
        .g = lerpChannel(left.g, right.g, amount),
        .b = lerpChannel(left.b, right.b, amount),
        .a = lerpChannel(left.a, right.a, amount),
    };
}

fn lerpChannel(left: u8, right: u8, amount: f32) u8 {
    const value = @as(f32, @floatFromInt(left)) + (@as(f32, @floatFromInt(right)) - @as(f32, @floatFromInt(left))) * amount;
    return @intFromFloat(@round(std.math.clamp(value, 0, 255)));
}

fn pngStoredDeflate(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const blocks = std.math.divCeil(usize, raw.len, 65535) catch return error.PngTooLarge;
    const block_bytes = std.math.mul(usize, blocks, 5) catch return error.PngTooLarge;
    const payload_bytes = std.math.add(usize, raw.len, block_bytes) catch return error.PngTooLarge;
    const total_bytes = std.math.add(usize, payload_bytes, 6) catch return error.PngTooLarge;
    const encoded = try allocator.alloc(u8, total_bytes);
    encoded[0..2].* = .{ 0x78, 0x01 };

    var src_index: usize = 0;
    var dst_index: usize = 2;
    while (src_index < raw.len) {
        const remaining = raw.len - src_index;
        const len: u16 = @intCast(@min(remaining, 65535));
        encoded[dst_index] = if (remaining <= 65535) 1 else 0;
        std.mem.writeInt(u16, encoded[dst_index + 1 ..][0..2], len, .little);
        std.mem.writeInt(u16, encoded[dst_index + 3 ..][0..2], ~len, .little);
        dst_index += 5;
        @memcpy(encoded[dst_index..][0..len], raw[src_index..][0..len]);
        src_index += len;
        dst_index += len;
    }
    std.mem.writeInt(u32, encoded[dst_index..][0..4], std.hash.Adler32.hash(raw), .big);
    return encoded;
}

fn writePngChunk(out: *std.Io.Writer, kind: []const u8, data: []const u8) !void {
    if (kind.len != 4) return error.InvalidPngChunk;
    const len = std.math.cast(u32, data.len) orelse return error.PngTooLarge;
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, len, .big);
    try out.writeAll(&length);
    try out.writeAll(kind);
    try out.writeAll(data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    var checksum: [4]u8 = undefined;
    std.mem.writeInt(u32, &checksum, crc.final(), .big);
    try out.writeAll(&checksum);
}

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

test "canvas writes decodable RGBA PNG" {
    var canvas = try Canvas.init(std.testing.allocator, 2, 1);
    defer canvas.deinit();
    canvas.pixels[0] = Color.rgba(1, 2, 3, 4);
    canvas.pixels[1] = Color.rgba(5, 6, 7, 8);

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try canvas.writePng(&output.writer);
    const bytes = output.written();
    try std.testing.expectEqualStrings("\x89PNG\r\n\x1a\n", bytes[0..8]);

    var decoded = try Image.decode(std.testing.allocator, bytes, .{});
    defer decoded.deinit();
    try std.testing.expectEqual(@as(u32, 2), decoded.width);
    try std.testing.expectEqual(@as(u32, 1), decoded.height);
    try std.testing.expectEqual(Color.rgba(1, 2, 3, 4), decoded.pixels[0]);
    try std.testing.expectEqual(Color.rgba(5, 6, 7, 8), decoded.pixels[1]);
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

test "render surfaces start transparent and validate their dimensions" {
    var surface = try RenderSurface.init(std.testing.allocator, 2, 3);
    defer surface.deinit();
    try std.testing.expectEqual(@as(u32, 2), surface.width());
    try std.testing.expectEqual(@as(u32, 3), surface.height());
    try std.testing.expectEqual(Color.transparent, surface.canvas().get(0, 0).?);
    try std.testing.expectError(error.InvalidRenderSurfaceSize, RenderSurface.init(std.testing.allocator, 0, 1));
    try std.testing.expectError(error.InvalidRenderSurfaceSize, RenderSurface.init(std.testing.allocator, 1, 0));
}

test "render surfaces compose, scale, tint, and respect Canvas clipping" {
    var surface = try RenderSurface.init(std.testing.allocator, 2, 1);
    defer surface.deinit();
    surface.canvas().clear(Color.transparent);
    surface.canvas().pixel(0, 0, Color.rgb(255, 0, 0));
    surface.canvas().pixel(1, 0, Color.rgb(0, 0, 255));

    var canvas = try Canvas.init(std.testing.allocator, 6, 2);
    defer canvas.deinit();
    canvas.clear(Color.black);
    try canvas.drawSurface(&surface, .{ .x = 0, .y = 0, .width = 3, .height = 1 });
    try std.testing.expectEqual(Color.rgb(255, 0, 0), canvas.get(0, 0).?);
    try std.testing.expectEqual(Color.rgb(255, 0, 0), canvas.get(1, 0).?);
    try std.testing.expectEqual(Color.rgb(0, 0, 255), canvas.get(2, 0).?);

    try canvas.drawSurface(&surface, .{ .x = 3, .y = 0, .width = 3, .height = 1, .filter = .linear });
    try std.testing.expectEqual(Color.rgb(255, 0, 0), canvas.get(3, 0).?);
    try std.testing.expectEqual(Color.rgb(128, 0, 128), canvas.get(4, 0).?);
    try std.testing.expectEqual(Color.rgb(0, 0, 255), canvas.get(5, 0).?);

    const previous = canvas.pushClip(.{ .x = 0, .y = 1, .w = 1, .h = 1 });
    try canvas.drawSurface(&surface, .{ .x = 0, .y = 1, .width = 2, .height = 1, .tint = Color.rgb(128, 255, 255) });
    canvas.restoreClip(previous);
    try std.testing.expectEqual(Color.rgb(128, 0, 0), canvas.get(0, 1).?);
    try std.testing.expectEqual(Color.black, canvas.get(1, 1).?);
}

test "render surfaces remain mutable and reject self sampling" {
    var first = try RenderSurface.init(std.testing.allocator, 1, 1);
    defer first.deinit();
    var second = try RenderSurface.init(std.testing.allocator, 1, 1);
    defer second.deinit();
    first.canvas().clear(Color.rgb(255, 0, 0));
    second.canvas().clear(Color.rgb(0, 255, 0));

    var canvas = try Canvas.init(std.testing.allocator, 2, 1);
    defer canvas.deinit();
    canvas.clear(Color.black);
    try canvas.drawSurface(&first, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
    try canvas.drawSurface(&second, .{ .x = 1, .y = 0, .width = 1, .height = 1 });
    try std.testing.expectEqual(Color.rgb(255, 0, 0), canvas.get(0, 0).?);
    try std.testing.expectEqual(Color.rgb(0, 255, 0), canvas.get(1, 0).?);

    first.canvas().clear(Color.rgb(0, 0, 255));
    canvas.clear(Color.black);
    try canvas.drawSurface(&first, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
    try std.testing.expectEqual(Color.rgb(0, 0, 255), canvas.get(0, 0).?);
    try std.testing.expectError(error.SurfaceSelfSampling, first.canvas().drawSurface(&first, .{ .x = 0, .y = 0, .width = 1, .height = 1 }));
    try std.testing.expectError(error.InvalidSurfaceDrawSize, canvas.drawSurface(&second, .{ .x = 0, .y = 0, .width = 0, .height = 1 }));
}

test "render surface traces identify content rather than allocation" {
    var first_surface = try RenderSurface.init(std.testing.allocator, 1, 1);
    defer first_surface.deinit();
    var second_surface = try RenderSurface.init(std.testing.allocator, 1, 1);
    defer second_surface.deinit();
    first_surface.canvas().clear(Color.rgb(255, 0, 0));
    second_surface.canvas().clear(Color.rgb(255, 0, 0));

    var first_canvas = try Canvas.init(std.testing.allocator, 2, 2);
    defer first_canvas.deinit();
    var second_canvas = try Canvas.init(std.testing.allocator, 2, 2);
    defer second_canvas.deinit();
    var first_trace = canvas_trace.Trace.init(std.testing.allocator);
    defer first_trace.deinit();
    var second_trace = canvas_trace.Trace.init(std.testing.allocator);
    defer second_trace.deinit();
    first_canvas.attachTrace(&first_trace);
    second_canvas.attachTrace(&second_trace);
    try first_canvas.drawSurface(&first_surface, .{ .x = 0, .y = 0, .width = 2, .height = 2 });
    try second_canvas.drawSurface(&second_surface, .{ .x = 0, .y = 0, .width = 2, .height = 2 });
    try std.testing.expect((try first_trace.firstDifference(&second_trace)) == null);
    try std.testing.expectEqual(try first_trace.hash(), try second_trace.hash());
    try std.testing.expectEqual(canvas_trace.Trace.Kind.surface, std.meta.activeTag(first_trace.commandSlice()[0]));

    second_trace.reset();
    try second_canvas.drawSurface(&second_surface, .{ .x = 0, .y = 0, .width = 2, .height = 2, .filter = .linear });
    try std.testing.expectEqualStrings("filter", (try first_trace.firstDifference(&second_trace)).?.field);

    second_surface.canvas().clear(Color.rgb(0, 0, 255));
    second_trace.reset();
    try second_canvas.drawSurface(&second_surface, .{ .x = 0, .y = 0, .width = 2, .height = 2 });
    const difference = (try first_trace.firstDifference(&second_trace)).?;
    try std.testing.expectEqualStrings("resource", difference.field);
}

test "canvas trace records public operations without rasterization details" {
    var canvas = try Canvas.init(std.testing.allocator, 4, 4);
    defer canvas.deinit();
    var trace = canvas_trace.Trace.init(std.testing.allocator);
    defer trace.deinit();
    canvas.attachTrace(&trace);

    canvas.clear(Color.black);
    canvas.fillRect(1, 1, 2, 2, Color.white);
    canvas.strokeRect(0, 0, 4, 4, Color.rgb(1, 2, 3));
    canvas.line(0, 0, 3, 3, Color.rgb(4, 5, 6));

    const commands = trace.commandSlice();
    try std.testing.expectEqual(@as(usize, 4), commands.len);
    try std.testing.expectEqual(canvas_trace.Trace.Kind.clear, std.meta.activeTag(commands[0]));
    try std.testing.expectEqual(canvas_trace.Trace.Kind.fill_rect, std.meta.activeTag(commands[1]));
    try std.testing.expectEqual(canvas_trace.Trace.Kind.stroke_rect, std.meta.activeTag(commands[2]));
    try std.testing.expectEqual(canvas_trace.Trace.Kind.line, std.meta.activeTag(commands[3]));
}

test "image draw uses sprite path" {
    var canvas = try Canvas.init(std.testing.allocator, 2, 1);
    defer canvas.deinit();
    var trace = canvas_trace.Trace.init(std.testing.allocator);
    defer trace.deinit();
    canvas.attachTrace(&trace);

    const pixels = try std.testing.allocator.dupe(Color, &.{ Color.white, Color.transparent });
    var image = Image{ .allocator = std.testing.allocator, .width = 2, .height = 1, .pixels = pixels };
    defer image.deinit();

    canvas.clear(Color.black);
    canvas.drawImage(image, 0, 0);
    try std.testing.expectEqual(Color.white, canvas.get(0, 0).?);
    try std.testing.expectEqual(Color.black, canvas.get(1, 0).?);
    try std.testing.expectEqual(@as(usize, 2), trace.commandSlice().len);
    try std.testing.expectEqual(canvas_trace.Trace.Kind.image, std.meta.activeTag(trace.commandSlice()[1]));
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
    var trace = canvas_trace.Trace.init(std.testing.allocator);
    defer trace.deinit();
    canvas.attachTrace(&trace);
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
    try std.testing.expectEqual(@as(usize, 2), trace.commandSlice().len);
    try std.testing.expectEqual(canvas_trace.Trace.Kind.atlas_frame, std.meta.activeTag(trace.commandSlice()[1]));
}
