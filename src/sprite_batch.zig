const std = @import("std");
const Color = @import("color.zig").Color;
const Image = @import("image.zig").Image;
const Sampling = @import("atlas.zig").Sampling;

pub const SourceRect = struct { x: u32, y: u32, w: u32, h: u32 };
pub const Point = struct { x: f32, y: f32 };
pub const Uv = struct { x: f32, y: f32 };

pub const Vertex = extern struct {
    x: f32,
    y: f32,
    u: f32,
    v: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

pub const SpriteDraw = struct {
    image: *const Image,
    source: SourceRect,
    vertex_start: u32,
    sampling: Sampling,
};

pub const Batch = struct {
    image: *const Image,
    start: usize,
    len: usize,
};

pub const SpriteBatch = struct { // owns batch buffers allocated by init and borrows source Images; call deinit once.
    allocator: std.mem.Allocator,
    draws: std.ArrayList(SpriteDraw) = .empty,
    vertices: std.ArrayList(Vertex) = .empty,
    sorted: std.ArrayList(usize) = .empty,
    batches: std.ArrayList(Batch) = .empty,

    pub fn init(allocator: std.mem.Allocator) SpriteBatch {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SpriteBatch) void {
        self.draws.deinit(self.allocator);
        self.vertices.deinit(self.allocator);
        self.sorted.deinit(self.allocator);
        self.batches.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clear(self: *SpriteBatch) void {
        self.draws.clearRetainingCapacity();
        self.vertices.clearRetainingCapacity();
        self.sorted.clearRetainingCapacity();
        self.batches.clearRetainingCapacity();
    }

    pub fn appendQuad(self: *SpriteBatch, image: *const Image, source: SourceRect, positions: [4]Point, uvs: [4]Uv, tint: Color, sampling: Sampling) !void {
        try validate(image, source, positions, uvs);
        if (self.vertices.items.len > std.math.maxInt(u32) - 6) return error.TooManySprites;
        try self.draws.ensureUnusedCapacity(self.allocator, 1);
        try self.vertices.ensureUnusedCapacity(self.allocator, 6);
        const vertex_start: u32 = @intCast(self.vertices.items.len);
        const color = colorFloats(tint);
        self.vertices.appendAssumeCapacity(vertex(positions[0], uvs[0], color));
        self.vertices.appendAssumeCapacity(vertex(positions[1], uvs[1], color));
        self.vertices.appendAssumeCapacity(vertex(positions[2], uvs[2], color));
        self.vertices.appendAssumeCapacity(vertex(positions[0], uvs[0], color));
        self.vertices.appendAssumeCapacity(vertex(positions[2], uvs[2], color));
        self.vertices.appendAssumeCapacity(vertex(positions[3], uvs[3], color));
        self.draws.appendAssumeCapacity(.{ .image = image, .source = source, .vertex_start = vertex_start, .sampling = sampling });
    }

    pub fn sortByTexture(self: *SpriteBatch) !void {
        self.sorted.clearRetainingCapacity();
        self.batches.clearRetainingCapacity();
        try self.sorted.ensureTotalCapacity(self.allocator, self.draws.items.len);
        for (self.draws.items, 0..) |_, index| self.sorted.appendAssumeCapacity(index);
        std.mem.sort(usize, self.sorted.items, self, lessThan);
        for (self.sorted.items, 0..) |draw_index, index| {
            if (index == 0 or self.draws.items[draw_index].image != self.draws.items[self.sorted.items[index - 1]].image) {
                try self.batches.append(self.allocator, .{ .image = self.draws.items[draw_index].image, .start = index, .len = 1 });
            } else {
                self.batches.items[self.batches.items.len - 1].len += 1;
            }
        }
    }

    fn lessThan(self: *SpriteBatch, a: usize, b: usize) bool {
        const a_address = @intFromPtr(self.draws.items[a].image);
        const b_address = @intFromPtr(self.draws.items[b].image);
        return if (a_address == b_address) a < b else a_address < b_address;
    }
};

fn validate(image: *const Image, source: SourceRect, positions: [4]Point, uvs: [4]Uv) !void {
    if (source.w == 0 or source.h == 0) return error.InvalidSourceRect;
    if (source.x > image.width or source.y > image.height) return error.InvalidSourceRect;
    if (source.w > image.width - source.x or source.h > image.height - source.y) return error.InvalidSourceRect;
    for (positions) |position| if (!std.math.isFinite(position.x) or !std.math.isFinite(position.y)) return error.InvalidSpriteTransform;
    for (uvs) |uv| if (!std.math.isFinite(uv.x) or !std.math.isFinite(uv.y)) return error.InvalidSpriteTransform;
}

fn colorFloats(color: Color) [4]f32 {
    return .{
        @as(f32, @floatFromInt(color.r)) / 255,
        @as(f32, @floatFromInt(color.g)) / 255,
        @as(f32, @floatFromInt(color.b)) / 255,
        @as(f32, @floatFromInt(color.a)) / 255,
    };
}

fn vertex(position: Point, uv: Uv, color: [4]f32) Vertex {
    return .{ .x = position.x, .y = position.y, .u = uv.x, .v = uv.y, .r = color[0], .g = color[1], .b = color[2], .a = color[3] };
}

test "sprite batch keeps source regions, tint, and sampling" {
    const pixels = [_]Color{Color.white} ** 16;
    var image = Image{ .allocator = std.testing.allocator, .width = 4, .height = 4, .pixels = @constCast(&pixels) };
    var batch = SpriteBatch.init(std.testing.allocator);
    defer batch.deinit();
    try batch.appendQuad(&image, .{ .x = 2, .y = 1, .w = 1, .h = 2 }, .{ .{ .x = -1, .y = 1 }, .{ .x = 0, .y = 1 }, .{ .x = 0, .y = 0 }, .{ .x = -1, .y = 0 } }, .{ .{ .x = 0.5, .y = 0.25 }, .{ .x = 0.75, .y = 0.25 }, .{ .x = 0.75, .y = 0.75 }, .{ .x = 0.5, .y = 0.75 } }, Color.rgb(255, 128, 0), .linear);
    try std.testing.expectEqual(@as(usize, 1), batch.draws.items.len);
    try std.testing.expectEqual(@as(usize, 6), batch.vertices.items.len);
    try std.testing.expectEqual(@as(u32, 2), batch.draws.items[0].source.x);
    try std.testing.expectEqual(Sampling.linear, batch.draws.items[0].sampling);
    try std.testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), batch.vertices.items[0].g, 0.0001);
}

test "sprite batches group texture residency without changing quad offsets" {
    const pixels = [_]Color{Color.white};
    var image_a = Image{ .allocator = std.testing.allocator, .width = 1, .height = 1, .pixels = @constCast(&pixels) };
    var image_b = Image{ .allocator = std.testing.allocator, .width = 1, .height = 1, .pixels = @constCast(&pixels) };
    var batch = SpriteBatch.init(std.testing.allocator);
    defer batch.deinit();
    const positions = [_]Point{ .{ .x = -1, .y = 1 }, .{ .x = 0, .y = 1 }, .{ .x = 0, .y = 0 }, .{ .x = -1, .y = 0 } };
    const uvs = [_]Uv{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 1, .y = 1 }, .{ .x = 0, .y = 1 } };
    try batch.appendQuad(&image_b, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, positions, uvs, Color.white, .nearest);
    try batch.appendQuad(&image_a, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, positions, uvs, Color.white, .nearest);
    try batch.appendQuad(&image_b, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, positions, uvs, Color.white, .nearest);
    try batch.sortByTexture();
    try std.testing.expectEqual(@as(usize, 2), batch.batches.items.len);
    const b_batch = if (batch.batches.items[0].image == &image_b) batch.batches.items[0] else batch.batches.items[1];
    try std.testing.expectEqual(@as(usize, 2), b_batch.len);
    try std.testing.expectEqual(@as(u32, 12), batch.draws.items[2].vertex_start);
}
