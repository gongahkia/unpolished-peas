const std = @import("std");
const Canvas = @import("canvas.zig").Canvas;
const ClipRect = @import("canvas.zig").ClipRect;
const Color = @import("color.zig").Color;
const Image = @import("image.zig").Image;
const Vec2 = @import("math.zig").Vec2;
const Presentation = @import("presentation.zig").Presentation;

pub const Command = union(enum) {
    begin_frame: Color,
    clear: Color,
    rect: Rect,
    stroke_rect: Rect,
    circle: Circle,
    stroke_circle: Circle,
    line: Line,
    triangle: Triangle,
    stroke_triangle: Triangle,
    image: ImageDraw,
    text: Text,
    push_clip: ClipRect,
    pop_clip,
    present: Presentation,
};

pub const Rect = struct { x: i32, y: i32, w: i32, h: i32, color: Color };
pub const Circle = struct { x: i32, y: i32, radius: i32, color: Color };
pub const Line = struct { x0: i32, y0: i32, x1: i32, y1: i32, color: Color };
pub const Triangle = struct { a: Vec2, b: Vec2, c: Vec2, color: Color };
pub const ImageDraw = struct { image: *const Image, x: i32, y: i32 };
pub const Text = struct { value: []const u8, x: i32, y: i32, color: Color };

pub const CommandBuffer = struct {
    allocator: std.mem.Allocator,
    commands: std.ArrayList(Command) = .empty,

    pub fn init(allocator: std.mem.Allocator) CommandBuffer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CommandBuffer) void {
        self.commands.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn append(self: *CommandBuffer, command: Command) !void {
        try self.commands.append(self.allocator, command);
    }
};

pub const HeadlessRenderer = struct {
    canvas: *Canvas,
    clip_stack: std.ArrayList(?ClipRect) = .empty,

    pub fn init(canvas: *Canvas) HeadlessRenderer {
        return .{ .canvas = canvas };
    }

    pub fn deinit(self: *HeadlessRenderer, allocator: std.mem.Allocator) void {
        self.clip_stack.deinit(allocator);
        self.* = undefined;
    }

    pub fn submit(self: *HeadlessRenderer, allocator: std.mem.Allocator, commands: []const Command) !void {
        for (commands) |command| switch (command) {
            .begin_frame, .clear => |color| self.canvas.clear(color),
            .rect => |value| self.canvas.fillRect(value.x, value.y, value.w, value.h, value.color),
            .stroke_rect => |value| self.canvas.strokeRect(value.x, value.y, value.w, value.h, value.color),
            .circle => |value| self.canvas.fillCircle(value.x, value.y, value.radius, value.color),
            .stroke_circle => |value| strokeCircle(self.canvas, value),
            .line => |value| self.canvas.line(value.x0, value.y0, value.x1, value.y1, value.color),
            .triangle => |value| self.canvas.fillTriangle(value.a, value.b, value.c, value.color),
            .stroke_triangle => |value| {
                self.canvas.line(roundToI32(value.a.x), roundToI32(value.a.y), roundToI32(value.b.x), roundToI32(value.b.y), value.color);
                self.canvas.line(roundToI32(value.b.x), roundToI32(value.b.y), roundToI32(value.c.x), roundToI32(value.c.y), value.color);
                self.canvas.line(roundToI32(value.c.x), roundToI32(value.c.y), roundToI32(value.a.x), roundToI32(value.a.y), value.color);
            },
            .image => |value| self.canvas.drawImage(value.image.*, value.x, value.y),
            .text => |value| self.canvas.drawText(value.value, value.x, value.y, value.color),
            .push_clip => |value| try self.clip_stack.append(allocator, self.canvas.pushClip(value)),
            .pop_clip => self.canvas.restoreClip(self.clip_stack.pop() orelse return error.UnbalancedRenderState),
            .present => {},
        };
        if (self.clip_stack.items.len != 0) return error.UnbalancedRenderState;
    }
};

fn strokeCircle(canvas: *Canvas, value: Circle) void {
    if (value.radius <= 0) return;
    var index: u32 = 0;
    while (index < 32) : (index += 1) {
        const a = @as(f32, @floatFromInt(index)) * std.math.tau / 32;
        const b = @as(f32, @floatFromInt(index + 1)) * std.math.tau / 32;
        canvas.line(value.x + roundToI32(@cos(a) * @as(f32, @floatFromInt(value.radius))), value.y + roundToI32(@sin(a) * @as(f32, @floatFromInt(value.radius))), value.x + roundToI32(@cos(b) * @as(f32, @floatFromInt(value.radius))), value.y + roundToI32(@sin(b) * @as(f32, @floatFromInt(value.radius))), value.color);
    }
}

fn roundToI32(value: f32) i32 {
    return @intFromFloat(@round(value));
}

test "headless renderer executes command frames" {
    var canvas = try Canvas.init(std.testing.allocator, 4, 4);
    defer canvas.deinit();
    var commands = CommandBuffer.init(std.testing.allocator);
    defer commands.deinit();
    try commands.append(.{ .begin_frame = Color.black });
    try commands.append(.{ .push_clip = .{ .x = 1, .y = 1, .w = 2, .h = 2 } });
    try commands.append(.{ .rect = .{ .x = 0, .y = 0, .w = 4, .h = 4, .color = Color.white } });
    try commands.append(.pop_clip);
    try commands.append(.{ .present = .init(.{ .x = 4, .y = 4 }, .{ .x = 4, .y = 4 }, .stretch) });

    var renderer = HeadlessRenderer.init(&canvas);
    defer renderer.deinit(std.testing.allocator);
    try renderer.submit(std.testing.allocator, commands.commands.items);
    try std.testing.expectEqual(Color.black, canvas.get(0, 0).?);
    try std.testing.expectEqual(Color.white, canvas.get(1, 1).?);
}
