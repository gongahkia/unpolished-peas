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
    push_blend: BlendMode,
    pop_blend,
    present: Presentation,
};

pub const Rect = struct { x: i32, y: i32, w: i32, h: i32, color: Color };
pub const Circle = struct { x: i32, y: i32, radius: i32, color: Color };
pub const Line = struct { x0: i32, y0: i32, x1: i32, y1: i32, color: Color };
pub const Triangle = struct { a: Vec2, b: Vec2, c: Vec2, color: Color };
pub const ImageDraw = struct { image: *const Image, x: i32, y: i32 };
pub const Text = struct { value: []const u8, x: i32, y: i32, color: Color };
pub const BlendMode = @import("canvas.zig").BlendMode;

pub const CommandBuffer = struct { // owns command storage allocated by init; call deinit once after submission.
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

pub const HeadlessRenderer = struct { // borrows its Canvas and owns temporary stacks released by deinit.
    allocator: std.mem.Allocator,
    canvas: *Canvas,
    clip_stack: std.ArrayList(?ClipRect) = .empty,
    blend_stack: std.ArrayList(BlendMode) = .empty,

    pub fn init(allocator: std.mem.Allocator, canvas: *Canvas) HeadlessRenderer {
        return .{ .allocator = allocator, .canvas = canvas };
    }

    pub fn deinit(self: *HeadlessRenderer) void {
        self.clip_stack.deinit(self.allocator);
        self.blend_stack.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn submit(self: *HeadlessRenderer, commands: []const Command) !void {
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
            .push_clip => |value| try self.clip_stack.append(self.allocator, self.canvas.pushClip(value)),
            .pop_clip => self.canvas.restoreClip(self.clip_stack.pop() orelse return error.UnbalancedRenderState),
            .push_blend => |value| try self.blend_stack.append(self.allocator, self.canvas.setBlend(value)),
            .pop_blend => self.canvas.blend = self.blend_stack.pop() orelse return error.UnbalancedRenderState,
            .present => {},
        };
        if (self.clip_stack.items.len != 0 or self.blend_stack.items.len != 0) return error.UnbalancedRenderState;
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

test "headless renderer owns and releases stack storage" {
    var canvas = try Canvas.init(std.testing.allocator, 4, 4);
    defer canvas.deinit();
    var commands = CommandBuffer.init(std.testing.allocator);
    defer commands.deinit();
    try commands.append(.{ .begin_frame = Color.black });
    try commands.append(.{ .push_clip = .{ .x = 1, .y = 1, .w = 2, .h = 2 } });
    try commands.append(.{ .rect = .{ .x = 0, .y = 0, .w = 4, .h = 4, .color = Color.white } });
    try commands.append(.pop_clip);
    try commands.append(.{ .present = .init(.{ .x = 4, .y = 4 }, .{ .x = 4, .y = 4 }, .stretch) });

    var renderer = HeadlessRenderer.init(std.testing.allocator, &canvas);
    defer renderer.deinit();
    try renderer.submit(commands.commands.items);
    try std.testing.expectEqual(Color.black, canvas.get(0, 0).?);
    try std.testing.expectEqual(Color.white, canvas.get(1, 1).?);
}

test "headless renderer restores nested clip and blend state" {
    var canvas = try Canvas.init(std.testing.allocator, 5, 5);
    defer canvas.deinit();
    var commands = CommandBuffer.init(std.testing.allocator);
    defer commands.deinit();
    try commands.append(.{ .clear = Color.black });
    try commands.append(.{ .push_clip = .{ .x = 1, .y = 1, .w = 3, .h = 3 } });
    try commands.append(.{ .rect = .{ .x = 0, .y = 0, .w = 5, .h = 5, .color = Color.rgba(255, 0, 0, 128) } });
    try commands.append(.{ .push_clip = .{ .x = 2, .y = 2, .w = 2, .h = 2 } });
    try commands.append(.{ .push_blend = .additive });
    try commands.append(.{ .rect = .{ .x = 0, .y = 0, .w = 5, .h = 5, .color = Color.rgba(0, 0, 255, 128) } });
    try commands.append(.pop_blend);
    try commands.append(.pop_clip);
    try commands.append(.{ .rect = .{ .x = 0, .y = 0, .w = 5, .h = 5, .color = Color.rgba(0, 255, 0, 128) } });
    try commands.append(.pop_clip);
    try commands.append(.{ .rect = .{ .x = 0, .y = 0, .w = 1, .h = 1, .color = Color.rgba(255, 0, 0, 128) } });

    var renderer = HeadlessRenderer.init(std.testing.allocator, &canvas);
    defer renderer.deinit();
    try renderer.submit(commands.commands.items);
    try std.testing.expectEqual(Color.rgb(128, 0, 0), canvas.get(0, 0).?);
    try std.testing.expectEqual(Color.rgb(63, 128, 0), canvas.get(1, 1).?);
    try std.testing.expectEqual(Color.rgb(63, 128, 63), canvas.get(2, 2).?);
    try std.testing.expectEqual(Color.black, canvas.get(4, 4).?);
}
