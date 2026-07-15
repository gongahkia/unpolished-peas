const std = @import("std");
const up = @import("unpolished-peas").api;
const RenderRect = @TypeOf(@as(up.RenderCommand, .{ .rect = undefined }).rect);
const RenderCircle = @TypeOf(@as(up.RenderCommand, .{ .circle = undefined }).circle);
const RenderLine = @TypeOf(@as(up.RenderCommand, .{ .line = undefined }).line);
const RenderTriangle = @TypeOf(@as(up.RenderCommand, .{ .triangle = undefined }).triangle);
const RenderText = @TypeOf(@as(up.RenderCommand, .{ .text = undefined }).text);

pub fn append(batch: *up.PrimitiveBatch, width: u32, height: u32, commands: []const up.RenderCommand) !void {
    var clip_stack = std.ArrayList(?up.ClipRect).empty;
    defer clip_stack.deinit(batch.allocator);
    var blend_stack = std.ArrayList(up.BlendMode).empty;
    defer blend_stack.deinit(batch.allocator);
    var clip: ?up.ClipRect = null;
    var blend: up.BlendMode = .alpha;

    for (commands) |command| switch (command) {
        .begin_frame, .clear, .image, .present => {},
        .push_clip => |next| {
            try clip_stack.append(batch.allocator, clip);
            clip = if (clip) |current| intersectClip(current, next) else next;
        },
        .pop_clip => clip = clip_stack.pop() orelse return error.UnbalancedRenderState,
        .push_blend => |next| {
            try blend_stack.append(batch.allocator, blend);
            blend = next;
        },
        .pop_blend => blend = blend_stack.pop() orelse return error.UnbalancedRenderState,
        .rect => |value| try appendRect(batch, width, height, value, blend, clip),
        .stroke_rect => |value| try appendStrokeRect(batch, width, height, value, blend, clip),
        .circle => |value| try appendCircle(batch, width, height, value, blend, clip),
        .stroke_circle => |value| try appendStrokeCircle(batch, width, height, value, blend, clip),
        .line => |value| try appendLine(batch, width, height, value, blend, clip),
        .triangle => |value| try appendTriangle(batch, width, height, value, blend, clip),
        .stroke_triangle => |value| try appendStrokeTriangle(batch, width, height, value, blend, clip),
        .text => |value| try appendText(batch, width, height, value, blend, clip),
    };
    if (clip_stack.items.len != 0 or blend_stack.items.len != 0) return error.UnbalancedRenderState;
}

fn appendRect(batch: *up.PrimitiveBatch, width: u32, height: u32, value: RenderRect, blend: up.BlendMode, clip: ?up.ClipRect) !void {
    const start: u32 = @intCast(batch.vertices.items.len);
    try batch.rect(width, height, value.x, value.y, value.w, value.h, value.color);
    try batch.finishDraw(start, blend, clip);
}

fn appendStrokeRect(batch: *up.PrimitiveBatch, width: u32, height: u32, value: RenderRect, blend: up.BlendMode, clip: ?up.ClipRect) !void {
    const start: u32 = @intCast(batch.vertices.items.len);
    try batch.strokeRect(width, height, value.x, value.y, value.w, value.h, value.color);
    try batch.finishDraw(start, blend, clip);
}

fn appendCircle(batch: *up.PrimitiveBatch, width: u32, height: u32, value: RenderCircle, blend: up.BlendMode, clip: ?up.ClipRect) !void {
    const start: u32 = @intCast(batch.vertices.items.len);
    try batch.circle(width, height, .{ .x = @floatFromInt(value.x), .y = @floatFromInt(value.y) }, value.radius, value.color);
    try batch.finishDraw(start, blend, clip);
}

fn appendStrokeCircle(batch: *up.PrimitiveBatch, width: u32, height: u32, value: RenderCircle, blend: up.BlendMode, clip: ?up.ClipRect) !void {
    const start: u32 = @intCast(batch.vertices.items.len);
    try batch.strokeCircle(width, height, .{ .x = @floatFromInt(value.x), .y = @floatFromInt(value.y) }, value.radius, value.color);
    try batch.finishDraw(start, blend, clip);
}

fn appendLine(batch: *up.PrimitiveBatch, width: u32, height: u32, value: RenderLine, blend: up.BlendMode, clip: ?up.ClipRect) !void {
    const start: u32 = @intCast(batch.vertices.items.len);
    try batch.line(width, height, .{ .x = @floatFromInt(value.x0), .y = @floatFromInt(value.y0) }, .{ .x = @floatFromInt(value.x1), .y = @floatFromInt(value.y1) }, value.color);
    try batch.finishDraw(start, blend, clip);
}

fn appendTriangle(batch: *up.PrimitiveBatch, width: u32, height: u32, value: RenderTriangle, blend: up.BlendMode, clip: ?up.ClipRect) !void {
    const start: u32 = @intCast(batch.vertices.items.len);
    try batch.triangle(width, height, .{ .x = value.a.x, .y = value.a.y }, .{ .x = value.b.x, .y = value.b.y }, .{ .x = value.c.x, .y = value.c.y }, value.color);
    try batch.finishDraw(start, blend, clip);
}

fn appendStrokeTriangle(batch: *up.PrimitiveBatch, width: u32, height: u32, value: RenderTriangle, blend: up.BlendMode, clip: ?up.ClipRect) !void {
    const start: u32 = @intCast(batch.vertices.items.len);
    try batch.strokeTriangle(width, height, .{ .x = value.a.x, .y = value.a.y }, .{ .x = value.b.x, .y = value.b.y }, .{ .x = value.c.x, .y = value.c.y }, value.color);
    try batch.finishDraw(start, blend, clip);
}

fn appendText(batch: *up.PrimitiveBatch, width: u32, height: u32, value: RenderText, blend: up.BlendMode, clip: ?up.ClipRect) !void {
    const start: u32 = @intCast(batch.vertices.items.len);
    try batch.text(width, height, value.value, value.x, value.y, value.color);
    try batch.finishDraw(start, blend, clip);
}

fn intersectClip(a: up.ClipRect, b: up.ClipRect) up.ClipRect {
    const x = @max(@as(i64, a.x), @as(i64, b.x));
    const y = @max(@as(i64, a.y), @as(i64, b.y));
    const right = @min(@as(i64, a.x) + a.w, @as(i64, b.x) + b.w);
    const bottom = @min(@as(i64, a.y) + a.h, @as(i64, b.y) + b.h);
    return .{ .x = clampI64ToI32(x), .y = clampI64ToI32(y), .w = clampI64ToI32(@max(@as(i64, 0), right - x)), .h = clampI64ToI32(@max(@as(i64, 0), bottom - y)) };
}

fn clampI64ToI32(value: i64) i32 {
    return @intCast(@max(@as(i64, std.math.minInt(i32)), @min(@as(i64, std.math.maxInt(i32)), value)));
}

test "primitive commands preserve canonical text, clip, and blend draws" {
    var commands = up.RenderCommandBuffer.init(std.testing.allocator);
    defer commands.deinit();
    try commands.append(.{ .push_clip = .{ .x = 1, .y = 1, .w = 3, .h = 3 } });
    try commands.append(.{ .push_blend = .additive });
    try commands.append(.{ .text = .{ .value = "A", .x = 1, .y = 1, .color = up.Color.white } });
    try commands.append(.pop_blend);
    try commands.append(.pop_clip);
    var batch = up.PrimitiveBatch.init(std.testing.allocator);
    defer batch.deinit();
    try append(&batch, 8, 8, commands.commands.items);
    try std.testing.expect(batch.vertices.items.len > 0);
    try std.testing.expectEqual(@as(usize, 1), batch.draws.items.len);
    try std.testing.expectEqual(up.BlendMode.additive, batch.draws.items[0].blend);
    try std.testing.expectEqual(up.ClipRect{ .x = 1, .y = 1, .w = 3, .h = 3 }, batch.draws.items[0].clip.?);
}
