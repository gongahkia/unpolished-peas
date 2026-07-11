const std = @import("std");
const Color = @import("color.zig").Color;
const Image = @import("image.zig").Image;

pub const SourceRect = struct { x: u32, y: u32, w: u32, h: u32 };

pub const SpriteDraw = struct {
    image: *const Image,
    source: SourceRect,
    x: i32,
    y: i32,
    scale: u32 = 1,
    flip_x: bool = false,
    flip_y: bool = false,
    tint: Color = Color.white,
};

pub const Batch = struct {
    image: *const Image,
    start: usize,
    len: usize,
};

pub const SpriteBatch = struct {
    allocator: std.mem.Allocator,
    draws: std.ArrayList(SpriteDraw) = .empty,
    sorted: std.ArrayList(usize) = .empty,
    batches: std.ArrayList(Batch) = .empty,

    pub fn init(allocator: std.mem.Allocator) SpriteBatch {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SpriteBatch) void {
        self.draws.deinit(self.allocator);
        self.sorted.deinit(self.allocator);
        self.batches.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clear(self: *SpriteBatch) void {
        self.draws.clearRetainingCapacity();
        self.sorted.clearRetainingCapacity();
        self.batches.clearRetainingCapacity();
    }

    pub fn append(self: *SpriteBatch, draw: SpriteDraw) !void {
        if (draw.source.w == 0 or draw.source.h == 0 or draw.scale == 0) return error.InvalidSourceRect;
        if (draw.source.x > draw.image.width or draw.source.y > draw.image.height) return error.InvalidSourceRect;
        if (draw.source.w > draw.image.width - draw.source.x or draw.source.h > draw.image.height - draw.source.y) return error.InvalidSourceRect;
        try self.draws.append(self.allocator, draw);
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

test "sprite batches preserve atlas regions and bound batches per texture" {
    const pixels = [_]Color{Color.white} ** 16;
    var image_a = Image{ .allocator = std.testing.allocator, .width = 4, .height = 4, .pixels = @constCast(&pixels) };
    var image_b = Image{ .allocator = std.testing.allocator, .width = 4, .height = 4, .pixels = @constCast(&pixels) };
    var batch = SpriteBatch.init(std.testing.allocator);
    defer batch.deinit();
    try batch.append(.{ .image = &image_b, .source = .{ .x = 2, .y = 1, .w = 1, .h = 2 }, .x = 0, .y = 0 });
    try batch.append(.{ .image = &image_a, .source = .{ .x = 0, .y = 0, .w = 2, .h = 2 }, .x = 3, .y = 4 });
    try batch.append(.{ .image = &image_b, .source = .{ .x = 0, .y = 2, .w = 2, .h = 1 }, .x = 5, .y = 6 });
    try batch.sortByTexture();
    try std.testing.expectEqual(@as(usize, 2), batch.batches.items.len);
    const b_batch = if (batch.batches.items[0].image == &image_b) batch.batches.items[0] else batch.batches.items[1];
    try std.testing.expectEqual(@as(usize, 2), b_batch.len);
    const b_draw = batch.draws.items[batch.sorted.items[b_batch.start]];
    try std.testing.expectEqual(@as(u32, 2), b_draw.source.x);
    try std.testing.expectEqual(@as(u32, 1), b_draw.source.y);
}

test "sprite batch keeps a large texture group bounded" {
    const pixels = [_]Color{Color.white};
    var image = Image{ .allocator = std.testing.allocator, .width = 1, .height = 1, .pixels = @constCast(&pixels) };
    var batch = SpriteBatch.init(std.testing.allocator);
    defer batch.deinit();
    for (0..10_000) |index| try batch.append(.{ .image = &image, .source = .{ .x = 0, .y = 0, .w = 1, .h = 1 }, .x = @intCast(index), .y = 0 });
    try batch.sortByTexture();
    try std.testing.expectEqual(@as(usize, 1), batch.batches.items.len);
    try std.testing.expectEqual(@as(usize, 10_000), batch.batches.items[0].len);
}
