const std = @import("std");
const Rect = @import("math.zig").Rect;
const collision = @import("collision.zig");

pub const Proxy = struct { index: u32, generation: u32 }; // borrows a Broadphase entry; stale update/remove returns error.StaleProxy.

pub const Broadphase = struct { // owns entries and query bookkeeping allocated by init; call deinit once.
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    free: std.ArrayList(u32) = .empty,

    const Entry = struct { bounds: Rect = .{}, generation: u32 = 1, live: bool = false };

    pub fn init(allocator: std.mem.Allocator) Broadphase {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Broadphase) void {
        self.entries.deinit(self.allocator);
        self.free.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn insert(self: *Broadphase, bounds: Rect) !Proxy {
        if (self.free.pop()) |index| {
            self.entries.items[index].bounds = bounds;
            self.entries.items[index].live = true;
            return .{ .index = index, .generation = self.entries.items[index].generation };
        }
        try self.entries.append(self.allocator, .{ .bounds = bounds, .live = true });
        return .{ .index = @intCast(self.entries.items.len - 1), .generation = 1 };
    }
    pub fn update(self: *Broadphase, proxy: Proxy, bounds: Rect) !void {
        try self.validate(proxy);
        self.entries.items[proxy.index].bounds = bounds;
    }
    pub fn remove(self: *Broadphase, proxy: Proxy) !void {
        try self.validate(proxy);
        var entry = &self.entries.items[proxy.index];
        entry.live = false;
        entry.generation +%= 1;
        if (entry.generation == 0) entry.generation = 1;
        try self.free.append(self.allocator, proxy.index);
    }
    pub fn query(self: *const Broadphase, allocator: std.mem.Allocator, bounds: Rect) ![]Proxy {
        var result = std.ArrayList(Proxy).empty;
        errdefer result.deinit(allocator);
        for (self.entries.items, 0..) |entry, index| if (entry.live and collision.rectOverlap(entry.bounds, bounds)) try result.append(allocator, .{ .index = @intCast(index), .generation = entry.generation });
        return result.toOwnedSlice(allocator);
    }
    fn validate(self: *const Broadphase, proxy: Proxy) !void {
        if (proxy.index >= self.entries.items.len) return error.StaleProxy;
        const entry = self.entries.items[proxy.index];
        if (!entry.live or entry.generation != proxy.generation) return error.StaleProxy;
    }
};

test "broadphase matches stable brute force order" {
    var broadphase = Broadphase.init(std.testing.allocator);
    defer broadphase.deinit();
    const a = try broadphase.insert(.init(0, 0, 2, 2));
    const b = try broadphase.insert(.init(5, 0, 2, 2));
    const c = try broadphase.insert(.init(1, 1, 2, 2));
    const result = try broadphase.query(std.testing.allocator, .init(0, 0, 3, 3));
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualSlices(Proxy, &.{ a, c }, result);
    try broadphase.update(b, .init(2, 0, 1, 1));
    const updated = try broadphase.query(std.testing.allocator, .init(0, 0, 3, 3));
    defer std.testing.allocator.free(updated);
    try std.testing.expectEqualSlices(Proxy, &.{ a, b, c }, updated);
    try broadphase.remove(a);
    try std.testing.expectError(error.StaleProxy, broadphase.update(a, .{}));
}
