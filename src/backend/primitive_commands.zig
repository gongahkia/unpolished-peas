const std = @import("std");
const up = @import("api.zig");
const RenderRect = @TypeOf(@as(up.RenderCommand, .{ .rect = undefined }).rect);
const RenderCircle = @TypeOf(@as(up.RenderCommand, .{ .circle = undefined }).circle);
const RenderLine = @TypeOf(@as(up.RenderCommand, .{ .line = undefined }).line);
const RenderTriangle = @TypeOf(@as(up.RenderCommand, .{ .triangle = undefined }).triangle);
const RenderText = @TypeOf(@as(up.RenderCommand, .{ .text = undefined }).text);
const RenderImage = @TypeOf(@as(up.RenderCommand, .{ .image = undefined }).image);

pub const Operation = union(enum) {
    clear: up.Color,
    primitive: u32,
    sprite: u32,
};

pub fn append(batch: *up.PrimitiveBatch, width: u32, height: u32, commands: []const up.RenderCommand) !void {
    try appendInternal(batch, null, null, width, height, commands);
}

pub fn appendOrdered(primitives: *up.PrimitiveBatch, sprites: *up.SpriteBatch, operations: *std.ArrayList(Operation), width: u32, height: u32, commands: []const up.RenderCommand) !void {
    try appendInternal(primitives, sprites, operations, width, height, commands);
}

fn appendInternal(batch: *up.PrimitiveBatch, sprites: ?*up.SpriteBatch, operations: ?*std.ArrayList(Operation), width: u32, height: u32, commands: []const up.RenderCommand) !void {
    var clip_stack = std.ArrayList(?up.ClipRect).empty;
    defer clip_stack.deinit(batch.allocator);
    var blend_stack = std.ArrayList(up.BlendMode).empty;
    defer blend_stack.deinit(batch.allocator);
    var clip: ?up.ClipRect = null;
    var blend: up.BlendMode = .alpha;

    for (commands) |command| switch (command) {
        .begin_frame, .clear => |value| try appendClear(operations, batch.allocator, value),
        .image => |value| if (sprites) |target| try appendImage(target, operations, width, height, value, blend, clip),
        .present => {},
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
        .rect => |value| try appendRect(batch, operations, width, height, value, blend, clip),
        .stroke_rect => |value| try appendStrokeRect(batch, operations, width, height, value, blend, clip),
        .circle => |value| try appendCircle(batch, operations, width, height, value, blend, clip),
        .stroke_circle => |value| try appendStrokeCircle(batch, operations, width, height, value, blend, clip),
        .line => |value| try appendLine(batch, operations, width, height, value, blend, clip),
        .triangle => |value| try appendTriangle(batch, operations, width, height, value, blend, clip),
        .stroke_triangle => |value| try appendStrokeTriangle(batch, operations, width, height, value, blend, clip),
        .text => |value| try appendText(batch, operations, width, height, value, blend, clip),
    };
    if (clip_stack.items.len != 0 or blend_stack.items.len != 0) return error.UnbalancedRenderState;
}

fn appendClear(operations: ?*std.ArrayList(Operation), allocator: std.mem.Allocator, value: up.Color) !void {
    if (operations) |target| try target.append(allocator, .{ .clear = value });
}

fn finishPrimitive(batch: *up.PrimitiveBatch, operations: ?*std.ArrayList(Operation), draw_start: usize) !void {
    if (operations) |target| if (batch.draws.items.len > draw_start) try target.append(batch.allocator, .{ .primitive = @intCast(draw_start) });
}

fn appendRect(batch: *up.PrimitiveBatch, operations: ?*std.ArrayList(Operation), width: u32, height: u32, value: RenderRect, blend: up.BlendMode, clip: ?up.ClipRect) !void {
    const draw_start = batch.draws.items.len;
    const start: u32 = @intCast(batch.vertices.items.len);
    try batch.rect(width, height, value.x, value.y, value.w, value.h, value.color);
    try batch.finishDraw(start, blend, clip);
    try finishPrimitive(batch, operations, draw_start);
}

fn appendStrokeRect(batch: *up.PrimitiveBatch, operations: ?*std.ArrayList(Operation), width: u32, height: u32, value: RenderRect, blend: up.BlendMode, clip: ?up.ClipRect) !void {
    const draw_start = batch.draws.items.len;
    const start: u32 = @intCast(batch.vertices.items.len);
    try batch.strokeRect(width, height, value.x, value.y, value.w, value.h, value.color);
    try batch.finishDraw(start, blend, clip);
    try finishPrimitive(batch, operations, draw_start);
}

fn appendCircle(batch: *up.PrimitiveBatch, operations: ?*std.ArrayList(Operation), width: u32, height: u32, value: RenderCircle, blend: up.BlendMode, clip: ?up.ClipRect) !void {
    const draw_start = batch.draws.items.len;
    const start: u32 = @intCast(batch.vertices.items.len);
    try batch.circle(width, height, .{ .x = @floatFromInt(value.x), .y = @floatFromInt(value.y) }, value.radius, value.color);
    try batch.finishDraw(start, blend, clip);
    try finishPrimitive(batch, operations, draw_start);
}

fn appendStrokeCircle(batch: *up.PrimitiveBatch, operations: ?*std.ArrayList(Operation), width: u32, height: u32, value: RenderCircle, blend: up.BlendMode, clip: ?up.ClipRect) !void {
    const draw_start = batch.draws.items.len;
    const start: u32 = @intCast(batch.vertices.items.len);
    try batch.strokeCircle(width, height, .{ .x = @floatFromInt(value.x), .y = @floatFromInt(value.y) }, value.radius, value.color);
    try batch.finishDraw(start, blend, clip);
    try finishPrimitive(batch, operations, draw_start);
}

fn appendLine(batch: *up.PrimitiveBatch, operations: ?*std.ArrayList(Operation), width: u32, height: u32, value: RenderLine, blend: up.BlendMode, clip: ?up.ClipRect) !void {
    const draw_start = batch.draws.items.len;
    const start: u32 = @intCast(batch.vertices.items.len);
    try batch.line(width, height, .{ .x = @floatFromInt(value.x0), .y = @floatFromInt(value.y0) }, .{ .x = @floatFromInt(value.x1), .y = @floatFromInt(value.y1) }, value.color);
    try batch.finishDraw(start, blend, clip);
    try finishPrimitive(batch, operations, draw_start);
}

fn appendTriangle(batch: *up.PrimitiveBatch, operations: ?*std.ArrayList(Operation), width: u32, height: u32, value: RenderTriangle, blend: up.BlendMode, clip: ?up.ClipRect) !void {
    const draw_start = batch.draws.items.len;
    const start: u32 = @intCast(batch.vertices.items.len);
    try batch.triangle(width, height, .{ .x = value.a.x, .y = value.a.y }, .{ .x = value.b.x, .y = value.b.y }, .{ .x = value.c.x, .y = value.c.y }, value.color);
    try batch.finishDraw(start, blend, clip);
    try finishPrimitive(batch, operations, draw_start);
}

fn appendStrokeTriangle(batch: *up.PrimitiveBatch, operations: ?*std.ArrayList(Operation), width: u32, height: u32, value: RenderTriangle, blend: up.BlendMode, clip: ?up.ClipRect) !void {
    const draw_start = batch.draws.items.len;
    const start: u32 = @intCast(batch.vertices.items.len);
    try batch.strokeTriangle(width, height, .{ .x = value.a.x, .y = value.a.y }, .{ .x = value.b.x, .y = value.b.y }, .{ .x = value.c.x, .y = value.c.y }, value.color);
    try batch.finishDraw(start, blend, clip);
    try finishPrimitive(batch, operations, draw_start);
}

fn appendText(batch: *up.PrimitiveBatch, operations: ?*std.ArrayList(Operation), width: u32, height: u32, value: RenderText, blend: up.BlendMode, clip: ?up.ClipRect) !void {
    const draw_start = batch.draws.items.len;
    const start: u32 = @intCast(batch.vertices.items.len);
    try batch.text(width, height, value.value, value.x, value.y, value.color);
    try batch.finishDraw(start, blend, clip);
    try finishPrimitive(batch, operations, draw_start);
}

fn appendImage(batch: *up.SpriteBatch, operations: ?*std.ArrayList(Operation), width: u32, height: u32, value: RenderImage, blend: up.BlendMode, clip: ?up.ClipRect) !void {
    const draw_start: u32 = @intCast(batch.draws.items.len);
    const image_width: f32 = @floatFromInt(value.image.width);
    const image_height: f32 = @floatFromInt(value.image.height);
    const left: f32 = @floatFromInt(value.x);
    const top: f32 = @floatFromInt(value.y);
    try batch.appendQuadWithState(value.image, .{ .x = 0, .y = 0, .w = value.image.width, .h = value.image.height }, .{
        toClip(width, height, left, top),
        toClip(width, height, left + image_width, top),
        toClip(width, height, left + image_width, top + image_height),
        toClip(width, height, left, top + image_height),
    }, .{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 1, .y = 1 }, .{ .x = 0, .y = 1 } }, up.Color.white, .nearest, blend, clip);
    if (operations) |target| try target.append(batch.allocator, .{ .sprite = draw_start });
}

fn toClip(width: u32, height: u32, x: f32, y: f32) up.SpriteBatchPoint {
    return .{ .x = x * 2 / @as(f32, @floatFromInt(width)) - 1, .y = 1 - y * 2 / @as(f32, @floatFromInt(height)) };
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

test "ordered commands preserve image state and command order" {
    var pixels = [_]up.Color{up.Color.white};
    var image = up.Image{ .allocator = std.testing.allocator, .width = 1, .height = 1, .pixels = &pixels };
    var commands = up.RenderCommandBuffer.init(std.testing.allocator);
    defer commands.deinit();
    try commands.append(.{ .clear = up.Color.black });
    try commands.append(.{ .rect = .{ .x = 0, .y = 0, .w = 1, .h = 1, .color = up.Color.rgb(255, 0, 0) } });
    try commands.append(.{ .push_clip = .{ .x = 1, .y = 1, .w = 1, .h = 1 } });
    try commands.append(.{ .push_blend = .additive });
    try commands.append(.{ .image = .{ .image = &image, .x = 1, .y = 1 } });
    try commands.append(.pop_blend);
    try commands.append(.pop_clip);
    var primitives = up.PrimitiveBatch.init(std.testing.allocator);
    defer primitives.deinit();
    var sprites = up.SpriteBatch.init(std.testing.allocator);
    defer sprites.deinit();
    var operations = std.ArrayList(Operation).empty;
    defer operations.deinit(std.testing.allocator);
    try appendOrdered(&primitives, &sprites, &operations, 4, 4, commands.commands.items);
    try std.testing.expectEqual(@as(usize, 3), operations.items.len);
    try std.testing.expectEqual(@as(u32, 0), operations.items[1].primitive);
    try std.testing.expectEqual(@as(u32, 0), operations.items[2].sprite);
    try std.testing.expectEqual(up.BlendMode.additive, sprites.draws.items[0].blend);
    try std.testing.expectEqual(up.ClipRect{ .x = 1, .y = 1, .w = 1, .h = 1 }, sprites.draws.items[0].clip.?);
}
