const std = @import("std");
const ClipRect = @import("canvas.zig").ClipRect;
const BlendMode = @import("canvas.zig").BlendMode;
const Color = @import("color.zig").Color;
const font = @import("font.zig");
const text_layout = @import("text_layout.zig");

pub const Point = struct { x: f32, y: f32 };

pub const Vertex = extern struct {
    x: f32,
    y: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

pub const Draw = struct {
    vertex_start: u32,
    vertex_count: u32,
    blend: BlendMode,
    clip: ?ClipRect,
};

pub const PrimitiveBatch = struct { // owns vertex and draw buffers allocated by init; call deinit once.
    allocator: std.mem.Allocator,
    vertices: std.ArrayList(Vertex) = .empty,
    draws: std.ArrayList(Draw) = .empty,

    pub fn init(allocator: std.mem.Allocator) PrimitiveBatch {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PrimitiveBatch) void {
        self.vertices.deinit(self.allocator);
        self.draws.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clear(self: *PrimitiveBatch) void {
        self.vertices.clearRetainingCapacity();
        self.draws.clearRetainingCapacity();
    }

    pub fn finishDraw(self: *PrimitiveBatch, vertex_start: u32, blend: BlendMode, clip: ?ClipRect) !void {
        const start: usize = vertex_start;
        if (start > self.vertices.items.len) return error.InvalidPrimitiveDraw;
        const vertex_count = std.math.cast(u32, self.vertices.items.len - start) orelse return error.PrimitiveBatchTooLarge;
        if (vertex_count == 0) return;
        try self.draws.append(self.allocator, .{ .vertex_start = vertex_start, .vertex_count = vertex_count, .blend = blend, .clip = clip });
    }

    pub fn rect(self: *PrimitiveBatch, canvas_width: u32, canvas_height: u32, x: i32, y: i32, w: i32, h: i32, color: Color) !void {
        if (w <= 0 or h <= 0) return;
        const left: f32 = @floatFromInt(x);
        const top: f32 = @floatFromInt(y);
        const right: f32 = @floatFromInt(x + w);
        const bottom: f32 = @floatFromInt(y + h);
        try self.quad(canvas_width, canvas_height, .{ .x = left, .y = top }, .{ .x = right, .y = top }, .{ .x = right, .y = bottom }, .{ .x = left, .y = bottom }, color);
    }

    pub fn strokeRect(self: *PrimitiveBatch, canvas_width: u32, canvas_height: u32, x: i32, y: i32, w: i32, h: i32, color: Color) !void {
        if (w <= 0 or h <= 0) return;
        try self.rect(canvas_width, canvas_height, x, y, w, 1, color);
        if (h > 1) try self.rect(canvas_width, canvas_height, x, y + h - 1, w, 1, color);
        if (h > 2) {
            try self.rect(canvas_width, canvas_height, x, y + 1, 1, h - 2, color);
            if (w > 1) try self.rect(canvas_width, canvas_height, x + w - 1, y + 1, 1, h - 2, color);
        }
    }

    pub fn line(self: *PrimitiveBatch, canvas_width: u32, canvas_height: u32, from: Point, to: Point, color: Color) !void {
        const dx = to.x - from.x;
        const dy = to.y - from.y;
        const length = @sqrt(dx * dx + dy * dy);
        if (length == 0) return self.quad(canvas_width, canvas_height, .{ .x = from.x - 0.5, .y = from.y - 0.5 }, .{ .x = from.x + 0.5, .y = from.y - 0.5 }, .{ .x = from.x + 0.5, .y = from.y + 0.5 }, .{ .x = from.x - 0.5, .y = from.y + 0.5 }, color);
        const offset = Point{ .x = -dy / length * 0.5, .y = dx / length * 0.5 };
        try self.quad(canvas_width, canvas_height, .{ .x = from.x + offset.x, .y = from.y + offset.y }, .{ .x = to.x + offset.x, .y = to.y + offset.y }, .{ .x = to.x - offset.x, .y = to.y - offset.y }, .{ .x = from.x - offset.x, .y = from.y - offset.y }, color);
    }

    pub fn circle(self: *PrimitiveBatch, canvas_width: u32, canvas_height: u32, center: Point, radius: i32, color: Color) !void {
        if (radius <= 0) return;
        const r: f32 = @floatFromInt(radius);
        var index: u32 = 0;
        while (index < circle_segments) : (index += 1) {
            const a = @as(f32, @floatFromInt(index)) * std.math.tau / circle_segments;
            const b = @as(f32, @floatFromInt(index + 1)) * std.math.tau / circle_segments;
            try self.triangle(canvas_width, canvas_height, center, .{ .x = center.x + @cos(a) * r, .y = center.y + @sin(a) * r }, .{ .x = center.x + @cos(b) * r, .y = center.y + @sin(b) * r }, color);
        }
    }

    pub fn strokeCircle(self: *PrimitiveBatch, canvas_width: u32, canvas_height: u32, center: Point, radius: i32, color: Color) !void {
        if (radius <= 0) return;
        const outer: f32 = @floatFromInt(radius);
        const inner = @max(@as(f32, 0), outer - 1);
        var index: u32 = 0;
        while (index < circle_segments) : (index += 1) {
            const a = @as(f32, @floatFromInt(index)) * std.math.tau / circle_segments;
            const b = @as(f32, @floatFromInt(index + 1)) * std.math.tau / circle_segments;
            try self.quad(canvas_width, canvas_height, .{ .x = center.x + @cos(a) * inner, .y = center.y + @sin(a) * inner }, .{ .x = center.x + @cos(a) * outer, .y = center.y + @sin(a) * outer }, .{ .x = center.x + @cos(b) * outer, .y = center.y + @sin(b) * outer }, .{ .x = center.x + @cos(b) * inner, .y = center.y + @sin(b) * inner }, color);
        }
    }

    pub fn triangle(self: *PrimitiveBatch, canvas_width: u32, canvas_height: u32, a: Point, b: Point, c: Point, color: Color) !void {
        try self.vertices.ensureUnusedCapacity(self.allocator, 3);
        const rgba = colorFloats(color);
        self.vertices.appendAssumeCapacity(vertex(toClip(canvas_width, canvas_height, a), rgba));
        self.vertices.appendAssumeCapacity(vertex(toClip(canvas_width, canvas_height, b), rgba));
        self.vertices.appendAssumeCapacity(vertex(toClip(canvas_width, canvas_height, c), rgba));
    }

    pub fn strokeTriangle(self: *PrimitiveBatch, canvas_width: u32, canvas_height: u32, a: Point, b: Point, c: Point, color: Color) !void {
        try self.line(canvas_width, canvas_height, a, b, color);
        try self.line(canvas_width, canvas_height, b, c, color);
        try self.line(canvas_width, canvas_height, c, a, color);
    }

    pub fn text(self: *PrimitiveBatch, canvas_width: u32, canvas_height: u32, value: []const u8, x: i32, y: i32, color: Color) !void {
        var laid_out = try text_layout.layout(self.allocator, value, .{});
        defer laid_out.deinit();
        for (laid_out.glyphs) |glyph| {
            if (glyph.codepoint == ' ') continue;
            const codepoint: u8 = if (glyph.codepoint <= 0x7f) @intCast(glyph.codepoint) else '?';
            const glyph_rows = font.glyph(codepoint);
            for (glyph_rows, 0..) |row, row_index| {
                var col: usize = 0;
                while (col < font.width) : (col += 1) {
                    const shift: u3 = @intCast(font.width - 1 - col);
                    if (((row >> shift) & 1) != 0) try self.rect(canvas_width, canvas_height, x + glyph.x + @as(i32, @intCast(col)), y + glyph.y + @as(i32, @intCast(row_index)), 1, 1, color);
                }
            }
        }
    }

    fn quad(self: *PrimitiveBatch, canvas_width: u32, canvas_height: u32, a: Point, b: Point, c: Point, d: Point, color: Color) !void {
        try self.vertices.ensureUnusedCapacity(self.allocator, 6);
        const rgba = colorFloats(color);
        self.vertices.appendAssumeCapacity(vertex(toClip(canvas_width, canvas_height, a), rgba));
        self.vertices.appendAssumeCapacity(vertex(toClip(canvas_width, canvas_height, b), rgba));
        self.vertices.appendAssumeCapacity(vertex(toClip(canvas_width, canvas_height, c), rgba));
        self.vertices.appendAssumeCapacity(vertex(toClip(canvas_width, canvas_height, a), rgba));
        self.vertices.appendAssumeCapacity(vertex(toClip(canvas_width, canvas_height, c), rgba));
        self.vertices.appendAssumeCapacity(vertex(toClip(canvas_width, canvas_height, d), rgba));
    }
};

const circle_segments: u32 = 32;

fn toClip(canvas_width: u32, canvas_height: u32, point: Point) Point {
    return .{ .x = point.x * 2 / @as(f32, @floatFromInt(canvas_width)) - 1, .y = 1 - point.y * 2 / @as(f32, @floatFromInt(canvas_height)) };
}

fn colorFloats(color: Color) [4]f32 {
    return .{ @as(f32, @floatFromInt(color.r)) / 255, @as(f32, @floatFromInt(color.g)) / 255, @as(f32, @floatFromInt(color.b)) / 255, @as(f32, @floatFromInt(color.a)) / 255 };
}

fn vertex(point: Point, color: [4]f32) Vertex {
    return .{ .x = point.x, .y = point.y, .r = color[0], .g = color[1], .b = color[2], .a = color[3] };
}

test "primitive batch produces alpha-colored triangles for every primitive" {
    var batch = PrimitiveBatch.init(std.testing.allocator);
    defer batch.deinit();
    const color = Color.rgba(255, 128, 0, 128);
    try batch.rect(32, 32, 1, 2, 3, 4, color);
    try batch.strokeRect(32, 32, 8, 2, 3, 4, color);
    try batch.line(32, 32, .{ .x = 0, .y = 0 }, .{ .x = 5, .y = 3 }, color);
    try batch.circle(32, 32, .{ .x = 16, .y = 16 }, 4, color);
    try batch.strokeCircle(32, 32, .{ .x = 16, .y = 16 }, 4, color);
    try batch.triangle(32, 32, .{ .x = 1, .y = 1 }, .{ .x = 4, .y = 1 }, .{ .x = 2, .y = 3 }, color);
    try batch.strokeTriangle(32, 32, .{ .x = 1, .y = 1 }, .{ .x = 4, .y = 1 }, .{ .x = 2, .y = 3 }, color);
    try batch.text(32, 32, "A", 1, 1, color);
    try std.testing.expect(batch.vertices.items.len > 6);
    try std.testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), batch.vertices.items[0].a, 0.0001);
}
