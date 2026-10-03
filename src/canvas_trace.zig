const std = @import("std");
const atlas = @import("atlas.zig");
const Color = @import("color.zig").Color;
const ClipRect = @import("canvas.zig").ClipRect;
const BlendMode = @import("canvas.zig").BlendMode;
const Vec2 = @import("math.zig").Vec2;

/// Test-only capture of one logical Canvas draw frame.
///
/// A trace records public Canvas requests, not rasterized pixels or backend
/// work. It has no allocation or hashing cost until a Canvas explicitly
/// attaches one.
pub const Trace = struct {
    const Self = @This();

    pub const Kind = enum(u8) {
        clear = 1,
        push_clip,
        restore_clip,
        set_blend,
        pixel,
        fill_rect,
        stroke_rect,
        fill_circle,
        fill_triangle,
        fill_quad,
        line,
        sprite,
        image,
        atlas_frame,
        text,
    };

    pub const Resource = struct {
        width: u32,
        height: u32,
        /// FNV-1a digest of dimensions and RGBA pixels, never an address or
        /// backend handle. It is a practical test identity, not a security
        /// digest.
        content_hash: u64,
    };

    pub const Pixel = struct { x: i32, y: i32, color: Color };
    pub const Rect = struct { x: i32, y: i32, w: i32, h: i32, color: Color };
    pub const Circle = struct { x: i32, y: i32, radius: i32, color: Color };
    pub const Triangle = struct { a: Vec2, b: Vec2, c: Vec2, color: Color };
    pub const Quad = struct { a: Vec2, b: Vec2, c: Vec2, d: Vec2, color: Color };
    pub const Line = struct { x0: i32, y0: i32, x1: i32, y1: i32, color: Color };
    pub const SpriteDraw = struct { resource: Resource, x: i32, y: i32 };
    pub const ImageDraw = SpriteDraw;
    pub const Text = struct { value: []const u8, x: i32, y: i32, color: Color };
    pub const AtlasFrame = struct {
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        source_w: i32,
        source_h: i32,
        offset_x: i32,
        offset_y: i32,
        rotated: bool,
    };
    pub const AtlasFrameDraw = struct {
        resource: Resource,
        frame: AtlasFrame,
        x: i32,
        y: i32,
        origin: atlas.Origin,
        scale: u32,
        flip_x: bool,
        flip_y: bool,
        tint: Color,
        rotation: f32,
        sampling: atlas.Sampling,
    };

    pub const Command = union(Kind) {
        clear: Color,
        push_clip: ClipRect,
        restore_clip: ?ClipRect,
        set_blend: BlendMode,
        pixel: Pixel,
        fill_rect: Rect,
        stroke_rect: Rect,
        fill_circle: Circle,
        fill_triangle: Triangle,
        fill_quad: Quad,
        line: Line,
        sprite: SpriteDraw,
        image: ImageDraw,
        atlas_frame: AtlasFrameDraw,
        text: Text,
    };

    pub const Difference = struct {
        index: usize,
        field: []const u8,
        expected: ?Command,
        actual: ?Command,
    };

    allocator: std.mem.Allocator,
    commands: std.ArrayListUnmanaged(Command) = .{},
    failure: ?Failure = null,

    const Failure = enum { out_of_memory };

    pub fn init(allocator: std.mem.Allocator) Trace {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        self.clearRetainingCapacity();
        self.commands.deinit(self.allocator);
        self.* = undefined;
    }

    /// Starts a new draw-frame trace while retaining command-buffer capacity.
    pub fn reset(self: *Self) void {
        self.clearRetainingCapacity();
        self.failure = null;
    }

    pub fn commandSlice(self: *const Self) []const Command {
        return self.commands.items;
    }

    pub fn hash(self: *const Self) !u64 {
        try self.ensureAvailable();
        var encoder = Encoder.init("UPCT1");
        encoder.usize(self.commands.items.len);
        for (self.commands.items) |command| encoder.command(command);
        return encoder.finish();
    }

    /// Returns the first structural mismatch. The retained command values can
    /// then be formatted with `formatDifference` for test diagnostics.
    pub fn firstDifference(self: *const Self, actual: *const Self) !?Difference {
        try self.ensureAvailable();
        try actual.ensureAvailable();
        const shared = @min(self.commands.items.len, actual.commands.items.len);
        for (self.commands.items[0..shared], actual.commands.items[0..shared], 0..) |expected, received, index| {
            if (commandDifference(expected, received)) |field| {
                return .{ .index = index, .field = field, .expected = expected, .actual = received };
            }
        }
        if (self.commands.items.len != actual.commands.items.len) {
            return .{
                .index = shared,
                .field = "command_count",
                .expected = if (shared < self.commands.items.len) self.commands.items[shared] else null,
                .actual = if (shared < actual.commands.items.len) actual.commands.items[shared] else null,
            };
        }
        return null;
    }

    /// Formats a concise first-difference diagnostic. Human formatting is for
    /// debugging only; canonical hashing is field-by-field binary encoding.
    pub fn formatDifference(difference: Difference, buffer: []u8) ![]const u8 {
        var expected_buffer: [192]u8 = undefined;
        var actual_buffer: [192]u8 = undefined;
        const expected = try formatOptionalCommand(difference.expected, &expected_buffer);
        const actual = try formatOptionalCommand(difference.actual, &actual_buffer);
        return std.fmt.bufPrint(buffer, "Canvas command mismatch at index {d}; field={s}\nexpected: {s}\nactual:   {s}", .{ difference.index, difference.field, expected, actual });
    }

    pub fn recordClear(self: *Self, color: Color) void {
        self.append(.{ .clear = color });
    }

    pub fn recordPushClip(self: *Self, value: ClipRect) void {
        self.append(.{ .push_clip = value });
    }

    pub fn recordRestoreClip(self: *Self, value: ?ClipRect) void {
        self.append(.{ .restore_clip = value });
    }

    pub fn recordSetBlend(self: *Self, value: BlendMode) void {
        self.append(.{ .set_blend = value });
    }

    pub fn recordPixel(self: *Self, x: i32, y: i32, color: Color) void {
        self.append(.{ .pixel = .{ .x = x, .y = y, .color = color } });
    }

    pub fn recordFillRect(self: *Self, x: i32, y: i32, w: i32, h: i32, color: Color) void {
        self.append(.{ .fill_rect = .{ .x = x, .y = y, .w = w, .h = h, .color = color } });
    }

    pub fn recordStrokeRect(self: *Self, x: i32, y: i32, w: i32, h: i32, color: Color) void {
        self.append(.{ .stroke_rect = .{ .x = x, .y = y, .w = w, .h = h, .color = color } });
    }

    pub fn recordFillCircle(self: *Self, x: i32, y: i32, radius: i32, color: Color) void {
        self.append(.{ .fill_circle = .{ .x = x, .y = y, .radius = radius, .color = color } });
    }

    pub fn recordFillTriangle(self: *Self, a: Vec2, b: Vec2, c: Vec2, color: Color) void {
        self.append(.{ .fill_triangle = .{ .a = a, .b = b, .c = c, .color = color } });
    }

    pub fn recordFillQuad(self: *Self, a: Vec2, b: Vec2, c: Vec2, d: Vec2, color: Color) void {
        self.append(.{ .fill_quad = .{ .a = a, .b = b, .c = c, .d = d, .color = color } });
    }

    pub fn recordLine(self: *Self, x0: i32, y0: i32, x1: i32, y1: i32, color: Color) void {
        self.append(.{ .line = .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1, .color = color } });
    }

    pub fn recordSprite(self: *Self, width: u32, height: u32, pixels: []const Color, x: i32, y: i32) void {
        self.append(.{ .sprite = .{ .resource = resource(width, height, pixels), .x = x, .y = y } });
    }

    pub fn recordImage(self: *Self, width: u32, height: u32, pixels: []const Color, x: i32, y: i32) void {
        self.append(.{ .image = .{ .resource = resource(width, height, pixels), .x = x, .y = y } });
    }

    pub fn recordAtlasFrame(self: *Self, image_width: u32, image_height: u32, image_pixels: []const Color, value: atlas.AtlasFrame, x: i32, y: i32, options: atlas.DrawSpriteOptions) void {
        self.append(.{ .atlas_frame = .{
            .resource = resource(image_width, image_height, image_pixels),
            .frame = .{
                .x = value.x,
                .y = value.y,
                .w = value.w,
                .h = value.h,
                .source_w = value.source_w,
                .source_h = value.source_h,
                .offset_x = value.offset_x,
                .offset_y = value.offset_y,
                .rotated = value.rotated,
            },
            .x = x,
            .y = y,
            .origin = options.origin,
            .scale = options.scale,
            .flip_x = options.flip_x,
            .flip_y = options.flip_y,
            .tint = options.tint,
            .rotation = options.rotation,
            .sampling = options.sampling,
        } });
    }

    pub fn recordText(self: *Self, value: []const u8, x: i32, y: i32, color: Color) void {
        if (self.failure != null) return;
        const copy = self.allocator.dupe(u8, value) catch {
            self.failure = .out_of_memory;
            return;
        };
        self.commands.append(self.allocator, .{ .text = .{ .value = copy, .x = x, .y = y, .color = color } }) catch {
            self.allocator.free(copy);
            self.failure = .out_of_memory;
        };
    }

    fn append(self: *Self, command: Command) void {
        if (self.failure != null) return;
        self.commands.append(self.allocator, command) catch self.failure = .out_of_memory;
    }

    fn clearRetainingCapacity(self: *Self) void {
        for (self.commands.items) |command| switch (command) {
            .text => |value| self.allocator.free(@constCast(value.value)),
            else => {},
        };
        self.commands.clearRetainingCapacity();
    }

    fn ensureAvailable(self: *const Self) !void {
        if (self.failure != null) return error.CanvasTraceOutOfMemory;
    }
};

const Encoder = struct {
    value: std.hash.Fnv1a_64 = std.hash.Fnv1a_64.init(),

    fn init(prefix: []const u8) Encoder {
        var result = Encoder{};
        result.bytes(prefix);
        return result;
    }

    fn finish(self: Encoder) u64 {
        var copy = self.value;
        return copy.final();
    }

    fn byte(self: *Encoder, value: u8) void {
        self.value.update(&.{value});
    }

    fn bool(self: *Encoder, value: bool) void {
        self.byte(@intFromBool(value));
    }

    fn u32(self: *Encoder, value: u32) void {
        self.byte(@truncate(value));
        self.byte(@truncate(value >> 8));
        self.byte(@truncate(value >> 16));
        self.byte(@truncate(value >> 24));
    }

    fn u64(self: *Encoder, value: u64) void {
        self.u32(@truncate(value));
        self.u32(@truncate(value >> 32));
    }

    fn usize(self: *Encoder, value: usize) void {
        self.u64(@intCast(value));
    }

    fn i32(self: *Encoder, value: i32) void {
        self.u32(@bitCast(value));
    }

    fn f32(self: *Encoder, value: f32) void {
        self.u32(@bitCast(value));
    }

    fn bytes(self: *Encoder, value: []const u8) void {
        self.usize(value.len);
        self.value.update(value);
    }

    fn color(self: *Encoder, value: Color) void {
        self.byte(value.r);
        self.byte(value.g);
        self.byte(value.b);
        self.byte(value.a);
    }

    fn vec2(self: *Encoder, value: Vec2) void {
        self.f32(value.x);
        self.f32(value.y);
    }

    fn clip(self: *Encoder, value: ClipRect) void {
        self.i32(value.x);
        self.i32(value.y);
        self.i32(value.w);
        self.i32(value.h);
    }

    fn optionalClip(self: *Encoder, value: ?ClipRect) void {
        self.bool(value != null);
        if (value) |clip| self.clip(clip);
    }

    fn resource(self: *Encoder, value: Trace.Resource) void {
        self.u32(value.width);
        self.u32(value.height);
        self.u64(value.content_hash);
    }

    fn command(self: *Encoder, value: Trace.Command) void {
        self.byte(@intFromEnum(std.meta.activeTag(value)));
        switch (value) {
            .clear => |color| self.color(color),
            .push_clip => |clip| self.clip(clip),
            .restore_clip => |clip| self.optionalClip(clip),
            .set_blend => |blend| self.byte(@intFromEnum(blend)),
            .pixel => |pixel| {
                self.i32(pixel.x);
                self.i32(pixel.y);
                self.color(pixel.color);
            },
            .fill_rect, .stroke_rect => |rect| {
                self.i32(rect.x);
                self.i32(rect.y);
                self.i32(rect.w);
                self.i32(rect.h);
                self.color(rect.color);
            },
            .fill_circle => |circle| {
                self.i32(circle.x);
                self.i32(circle.y);
                self.i32(circle.radius);
                self.color(circle.color);
            },
            .fill_triangle => |triangle| {
                self.vec2(triangle.a);
                self.vec2(triangle.b);
                self.vec2(triangle.c);
                self.color(triangle.color);
            },
            .fill_quad => |quad| {
                self.vec2(quad.a);
                self.vec2(quad.b);
                self.vec2(quad.c);
                self.vec2(quad.d);
                self.color(quad.color);
            },
            .line => |line| {
                self.i32(line.x0);
                self.i32(line.y0);
                self.i32(line.x1);
                self.i32(line.y1);
                self.color(line.color);
            },
            .sprite, .image => |draw| {
                self.resource(draw.resource);
                self.i32(draw.x);
                self.i32(draw.y);
            },
            .atlas_frame => |draw| {
                self.resource(draw.resource);
                self.i32(draw.frame.x);
                self.i32(draw.frame.y);
                self.i32(draw.frame.w);
                self.i32(draw.frame.h);
                self.i32(draw.frame.source_w);
                self.i32(draw.frame.source_h);
                self.i32(draw.frame.offset_x);
                self.i32(draw.frame.offset_y);
                self.bool(draw.frame.rotated);
                self.i32(draw.x);
                self.i32(draw.y);
                self.byte(@intFromEnum(draw.origin));
                self.u32(draw.scale);
                self.bool(draw.flip_x);
                self.bool(draw.flip_y);
                self.color(draw.tint);
                self.f32(draw.rotation);
                self.byte(@intFromEnum(draw.sampling));
            },
            .text => |text| {
                self.bytes(text.value);
                self.i32(text.x);
                self.i32(text.y);
                self.color(text.color);
            },
        }
    }
};

fn resource(width: u32, height: u32, pixels: []const Color) Trace.Resource {
    var encoder = Encoder.init("UPCT-resource-v1");
    encoder.u32(width);
    encoder.u32(height);
    encoder.usize(pixels.len);
    for (pixels) |pixel| encoder.color(pixel);
    return .{ .width = width, .height = height, .content_hash = encoder.finish() };
}

fn commandDifference(expected: Trace.Command, actual: Trace.Command) ?[]const u8 {
    if (std.meta.activeTag(expected) != std.meta.activeTag(actual)) return "variant";
    return switch (expected) {
        .clear => if (sameColor(expected.clear, actual.clear)) null else "color",
        .push_clip => if (sameClip(expected.push_clip, actual.push_clip)) null else "clip",
        .restore_clip => if (sameOptionalClip(expected.restore_clip, actual.restore_clip)) null else "clip",
        .set_blend => if (expected.set_blend == actual.set_blend) null else "blend",
        .pixel => differencePixel(expected.pixel, actual.pixel),
        .fill_rect => differenceRect(expected.fill_rect, actual.fill_rect),
        .stroke_rect => differenceRect(expected.stroke_rect, actual.stroke_rect),
        .fill_circle => differenceCircle(expected.fill_circle, actual.fill_circle),
        .fill_triangle => differenceTriangle(expected.fill_triangle, actual.fill_triangle),
        .fill_quad => differenceQuad(expected.fill_quad, actual.fill_quad),
        .line => differenceLine(expected.line, actual.line),
        .sprite => differenceSprite(expected.sprite, actual.sprite),
        .image => differenceSprite(expected.image, actual.image),
        .atlas_frame => differenceAtlas(expected.atlas_frame, actual.atlas_frame),
        .text => differenceText(expected.text, actual.text),
    };
}

fn differencePixel(expected: Trace.Pixel, actual: Trace.Pixel) ?[]const u8 {
    if (expected.x != actual.x) return "x";
    if (expected.y != actual.y) return "y";
    if (!sameColor(expected.color, actual.color)) return "color";
    return null;
}

fn differenceRect(expected: Trace.Rect, actual: Trace.Rect) ?[]const u8 {
    if (expected.x != actual.x) return "x";
    if (expected.y != actual.y) return "y";
    if (expected.w != actual.w) return "width";
    if (expected.h != actual.h) return "height";
    if (!sameColor(expected.color, actual.color)) return "color";
    return null;
}

fn differenceCircle(expected: Trace.Circle, actual: Trace.Circle) ?[]const u8 {
    if (expected.x != actual.x) return "x";
    if (expected.y != actual.y) return "y";
    if (expected.radius != actual.radius) return "radius";
    if (!sameColor(expected.color, actual.color)) return "color";
    return null;
}

fn differenceTriangle(expected: Trace.Triangle, actual: Trace.Triangle) ?[]const u8 {
    if (!sameVec2(expected.a, actual.a)) return "a";
    if (!sameVec2(expected.b, actual.b)) return "b";
    if (!sameVec2(expected.c, actual.c)) return "c";
    if (!sameColor(expected.color, actual.color)) return "color";
    return null;
}

fn differenceQuad(expected: Trace.Quad, actual: Trace.Quad) ?[]const u8 {
    if (!sameVec2(expected.a, actual.a)) return "a";
    if (!sameVec2(expected.b, actual.b)) return "b";
    if (!sameVec2(expected.c, actual.c)) return "c";
    if (!sameVec2(expected.d, actual.d)) return "d";
    if (!sameColor(expected.color, actual.color)) return "color";
    return null;
}

fn differenceLine(expected: Trace.Line, actual: Trace.Line) ?[]const u8 {
    if (expected.x0 != actual.x0) return "x0";
    if (expected.y0 != actual.y0) return "y0";
    if (expected.x1 != actual.x1) return "x1";
    if (expected.y1 != actual.y1) return "y1";
    if (!sameColor(expected.color, actual.color)) return "color";
    return null;
}

fn differenceSprite(expected: Trace.SpriteDraw, actual: Trace.SpriteDraw) ?[]const u8 {
    if (!sameResource(expected.resource, actual.resource)) return "resource";
    if (expected.x != actual.x) return "x";
    if (expected.y != actual.y) return "y";
    return null;
}

fn differenceAtlas(expected: Trace.AtlasFrameDraw, actual: Trace.AtlasFrameDraw) ?[]const u8 {
    if (!sameResource(expected.resource, actual.resource)) return "resource";
    if (!sameAtlasFrame(expected.frame, actual.frame)) return "frame";
    if (expected.x != actual.x) return "x";
    if (expected.y != actual.y) return "y";
    if (expected.origin != actual.origin) return "origin";
    if (expected.scale != actual.scale) return "scale";
    if (expected.flip_x != actual.flip_x) return "flip_x";
    if (expected.flip_y != actual.flip_y) return "flip_y";
    if (!sameColor(expected.tint, actual.tint)) return "tint";
    if (!sameF32(expected.rotation, actual.rotation)) return "rotation";
    if (expected.sampling != actual.sampling) return "sampling";
    return null;
}

fn differenceText(expected: Trace.Text, actual: Trace.Text) ?[]const u8 {
    if (!std.mem.eql(u8, expected.value, actual.value)) return "text";
    if (expected.x != actual.x) return "x";
    if (expected.y != actual.y) return "y";
    if (!sameColor(expected.color, actual.color)) return "color";
    return null;
}

fn sameColor(a: Color, b: Color) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
}

fn sameF32(a: f32, b: f32) bool {
    return @as(u32, @bitCast(a)) == @as(u32, @bitCast(b));
}

fn sameVec2(a: Vec2, b: Vec2) bool {
    return sameF32(a.x, b.x) and sameF32(a.y, b.y);
}

fn sameClip(a: ClipRect, b: ClipRect) bool {
    return a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h;
}

fn sameOptionalClip(a: ?ClipRect, b: ?ClipRect) bool {
    if (a == null or b == null) return a == null and b == null;
    return sameClip(a.?, b.?);
}

fn sameResource(a: Trace.Resource, b: Trace.Resource) bool {
    return a.width == b.width and a.height == b.height and a.content_hash == b.content_hash;
}

fn sameAtlasFrame(a: Trace.AtlasFrame, b: Trace.AtlasFrame) bool {
    return a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h and a.source_w == b.source_w and a.source_h == b.source_h and a.offset_x == b.offset_x and a.offset_y == b.offset_y and a.rotated == b.rotated;
}

fn formatOptionalCommand(command: ?Trace.Command, buffer: []u8) ![]const u8 {
    const value = command orelse return std.fmt.bufPrint(buffer, "<none>", .{});
    return switch (value) {
        .clear => |color| std.fmt.bufPrint(buffer, "clear rgba({d},{d},{d},{d})", .{ color.r, color.g, color.b, color.a }),
        .push_clip => |clip| std.fmt.bufPrint(buffer, "push_clip x={d} y={d} w={d} h={d}", .{ clip.x, clip.y, clip.w, clip.h }),
        .restore_clip => |clip| if (clip) |value| std.fmt.bufPrint(buffer, "restore_clip x={d} y={d} w={d} h={d}", .{ value.x, value.y, value.w, value.h }) else std.fmt.bufPrint(buffer, "restore_clip null", .{}),
        .set_blend => |blend| std.fmt.bufPrint(buffer, "set_blend {s}", .{@tagName(blend)}),
        .pixel => |pixel| std.fmt.bufPrint(buffer, "pixel x={d} y={d} rgba({d},{d},{d},{d})", .{ pixel.x, pixel.y, pixel.color.r, pixel.color.g, pixel.color.b, pixel.color.a }),
        .fill_rect, .stroke_rect => |rect| std.fmt.bufPrint(buffer, "{s} x={d} y={d} w={d} h={d} rgba({d},{d},{d},{d})", .{ @tagName(std.meta.activeTag(value)), rect.x, rect.y, rect.w, rect.h, rect.color.r, rect.color.g, rect.color.b, rect.color.a }),
        .fill_circle => |circle| std.fmt.bufPrint(buffer, "fill_circle x={d} y={d} radius={d} rgba({d},{d},{d},{d})", .{ circle.x, circle.y, circle.radius, circle.color.r, circle.color.g, circle.color.b, circle.color.a }),
        .fill_triangle => |triangle| std.fmt.bufPrint(buffer, "fill_triangle a=({d},{d}) b=({d},{d}) c=({d},{d})", .{ triangle.a.x, triangle.a.y, triangle.b.x, triangle.b.y, triangle.c.x, triangle.c.y }),
        .fill_quad => |quad| std.fmt.bufPrint(buffer, "fill_quad a=({d},{d}) b=({d},{d}) c=({d},{d}) d=({d},{d})", .{ quad.a.x, quad.a.y, quad.b.x, quad.b.y, quad.c.x, quad.c.y, quad.d.x, quad.d.y }),
        .line => |line| std.fmt.bufPrint(buffer, "line ({d},{d})->({d},{d}) rgba({d},{d},{d},{d})", .{ line.x0, line.y0, line.x1, line.y1, line.color.r, line.color.g, line.color.b, line.color.a }),
        .sprite, .image => |draw| std.fmt.bufPrint(buffer, "{s} resource={d}x{d}#{x} x={d} y={d}", .{ @tagName(std.meta.activeTag(value)), draw.resource.width, draw.resource.height, draw.resource.content_hash, draw.x, draw.y }),
        .atlas_frame => |draw| std.fmt.bufPrint(buffer, "atlas_frame resource={d}x{d}#{x} frame=({d},{d},{d},{d}) x={d} y={d} rotation={d}", .{ draw.resource.width, draw.resource.height, draw.resource.content_hash, draw.frame.x, draw.frame.y, draw.frame.w, draw.frame.h, draw.x, draw.y, draw.rotation }),
        .text => |text| std.fmt.bufPrint(buffer, "text value={s} x={d} y={d} rgba({d},{d},{d},{d})", .{ text.value, text.x, text.y, text.color.r, text.color.g, text.color.b, text.color.a }),
    };
}

test "empty traces have equal deterministic hashes" {
    var first = Trace.init(std.testing.allocator);
    defer first.deinit();
    var second = Trace.init(std.testing.allocator);
    defer second.deinit();
    try std.testing.expect((try first.firstDifference(&second)) == null);
    try std.testing.expectEqual(try first.hash(), try second.hash());
}

test "trace detects ordering fields text resources and float bits" {
    var first = Trace.init(std.testing.allocator);
    defer first.deinit();
    var second = Trace.init(std.testing.allocator);
    defer second.deinit();
    const pixels = [_]Color{ Color.white, Color.black };

    first.recordFillRect(20, 3, 4, 5, Color.white);
    first.recordText("peas", 1, 2, Color.rgb(1, 2, 3));
    first.recordSprite(2, 1, &pixels, 4, 5);
    first.recordFillTriangle(.{ .x = -0.0, .y = 1 }, .{ .x = 2, .y = 3 }, .{ .x = 4, .y = 5 }, Color.white);

    second.recordText("peas", 1, 2, Color.rgb(1, 2, 3));
    second.recordFillRect(20, 3, 4, 5, Color.white);
    second.recordSprite(2, 1, &pixels, 4, 5);
    second.recordFillTriangle(.{ .x = 0.0, .y = 1 }, .{ .x = 2, .y = 3 }, .{ .x = 4, .y = 5 }, Color.white);

    const ordering = (try first.firstDifference(&second)).?;
    try std.testing.expectEqualStrings("variant", ordering.field);
    try std.testing.expect((try first.hash()) != (try second.hash()));

    second.reset();
    second.recordFillRect(21, 3, 4, 5, Color.white);
    second.recordText("peas", 1, 2, Color.rgb(1, 2, 3));
    second.recordSprite(2, 1, &pixels, 4, 5);
    second.recordFillTriangle(.{ .x = -0.0, .y = 1 }, .{ .x = 2, .y = 3 }, .{ .x = 4, .y = 5 }, Color.white);
    const position = (try first.firstDifference(&second)).?;
    try std.testing.expectEqualStrings("x", position.field);
    var diagnostic: [512]u8 = undefined;
    const message = try Trace.formatDifference(position, &diagnostic);
    try std.testing.expect(std.mem.indexOf(u8, message, "fill_rect x=20") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "fill_rect x=21") != null);

    second.reset();
    second.recordFillRect(20, 3, 4, 5, Color.white);
    second.recordText("peas!", 1, 2, Color.rgb(1, 2, 3));
    second.recordSprite(2, 1, &pixels, 4, 5);
    second.recordFillTriangle(.{ .x = -0.0, .y = 1 }, .{ .x = 2, .y = 3 }, .{ .x = 4, .y = 5 }, Color.white);
    try std.testing.expectEqualStrings("text", (try first.firstDifference(&second)).?.field);

    second.reset();
    second.recordFillRect(20, 3, 4, 5, Color.white);
    second.recordText("peas", 1, 2, Color.rgb(1, 2, 3));
    const changed_pixels = [_]Color{ Color.black, Color.black };
    second.recordSprite(2, 1, &changed_pixels, 4, 5);
    second.recordFillTriangle(.{ .x = -0.0, .y = 1 }, .{ .x = 2, .y = 3 }, .{ .x = 4, .y = 5 }, Color.white);
    try std.testing.expectEqualStrings("resource", (try first.firstDifference(&second)).?.field);

    second.reset();
    second.recordFillRect(20, 3, 4, 5, Color.white);
    second.recordText("peas", 1, 2, Color.rgb(1, 2, 3));
    second.recordSprite(2, 1, &pixels, 4, 5);
    second.recordFillTriangle(.{ .x = 0.0, .y = 1 }, .{ .x = 2, .y = 3 }, .{ .x = 4, .y = 5 }, Color.white);
    try std.testing.expectEqualStrings("a", (try first.firstDifference(&second)).?.field);
}

test "trace reports command-count mismatch" {
    var expected = Trace.init(std.testing.allocator);
    defer expected.deinit();
    var actual = Trace.init(std.testing.allocator);
    defer actual.deinit();
    expected.recordClear(Color.black);
    actual.recordClear(Color.black);
    actual.recordFillRect(0, 0, 1, 1, Color.white);
    const difference = (try expected.firstDifference(&actual)).?;
    try std.testing.expectEqual(@as(usize, 1), difference.index);
    try std.testing.expectEqualStrings("command_count", difference.field);
}
