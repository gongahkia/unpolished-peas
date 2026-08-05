const std = @import("std");

pub const max_pooled_packet_buffers: usize = 64;
pub const max_fallback_packet_buffers: usize = 64;
pub const PacketBufferPoolError = error{ InvalidConfiguration, OutOfMemory, Exhausted, InvalidRelease };

pub const PacketBufferPoolConfig = struct {
    packet_capacity: usize,
    pooled_buffers: usize,
    fallback_buffers: usize,
};

pub const PacketBufferLease = struct {
    bytes: []u8,
    pooled_index: ?usize,
    fallback_index: ?usize,
};

pub const PacketBufferPool = struct {
    allocator: std.mem.Allocator,
    packet_capacity: usize,
    pooled_count: usize,
    fallback_count: usize,
    storage: []u8,
    available_pooled: u64,
    fallback_storage: [max_fallback_packet_buffers]?[]u8 = .{null} ** max_fallback_packet_buffers,

    pub fn init(allocator: std.mem.Allocator, config: PacketBufferPoolConfig) PacketBufferPoolError!PacketBufferPool {
        if (config.packet_capacity == 0 or config.pooled_buffers > max_pooled_packet_buffers or config.fallback_buffers > max_fallback_packet_buffers) return error.InvalidConfiguration;
        const total = std.math.mul(usize, config.packet_capacity, config.pooled_buffers) catch return error.InvalidConfiguration;
        const storage = allocator.alloc(u8, total) catch return error.OutOfMemory;
        return .{
            .allocator = allocator,
            .packet_capacity = config.packet_capacity,
            .pooled_count = config.pooled_buffers,
            .fallback_count = config.fallback_buffers,
            .storage = storage,
            .available_pooled = available_mask(config.pooled_buffers),
        };
    }

    pub fn acquire(self: *PacketBufferPool) PacketBufferPoolError!PacketBufferLease {
        if (self.available_pooled != 0) {
            const index: usize = @ctz(self.available_pooled);
            self.available_pooled &= ~(@as(u64, 1) << @intCast(index));
            const start = index * self.packet_capacity;
            return .{
                .bytes = self.storage[start .. start + self.packet_capacity],
                .pooled_index = index,
                .fallback_index = null,
            };
        }
        for (self.fallback_storage, 0..) |entry, index| {
            if (index == self.fallback_count) break;
            if (entry == null) {
                const bytes = self.allocator.alloc(u8, self.packet_capacity) catch return error.OutOfMemory;
                self.fallback_storage[index] = bytes;
                return .{
                    .bytes = bytes,
                    .pooled_index = null,
                    .fallback_index = index,
                };
            }
        }
        return error.Exhausted;
    }

    pub fn release(self: *PacketBufferPool, lease: *PacketBufferLease) PacketBufferPoolError!void {
        if (lease.pooled_index) |index| {
            if (index >= self.pooled_count or self.available_pooled & (@as(u64, 1) << @intCast(index)) != 0) return error.InvalidRelease;
            self.available_pooled |= @as(u64, 1) << @intCast(index);
        } else if (lease.fallback_index) |index| {
            if (index >= self.fallback_count) return error.InvalidRelease;
            const bytes = self.fallback_storage[index] orelse return error.InvalidRelease;
            if (bytes.ptr != lease.bytes.ptr or bytes.len != lease.bytes.len) return error.InvalidRelease;
            self.allocator.free(bytes);
            self.fallback_storage[index] = null;
        } else return error.InvalidRelease;
        lease.* = undefined;
    }

    pub fn deinit(self: *PacketBufferPool) void {
        for (self.fallback_storage[0..self.fallback_count]) |entry| if (entry) |bytes| self.allocator.free(bytes);
        self.allocator.free(self.storage);
        self.* = undefined;
    }
};

fn available_mask(count: usize) u64 {
    if (count == max_pooled_packet_buffers) return std.math.maxInt(u64);
    return (@as(u64, 1) << @intCast(count)) - 1;
}

test "packet buffer pools reuse bounded buffers then use allocator fallback" {
    var pool = try PacketBufferPool.init(std.testing.allocator, .{
        .packet_capacity = 8,
        .pooled_buffers = 1,
        .fallback_buffers = 1,
    });
    defer pool.deinit();
    var pooled = try pool.acquire();
    const pooled_ptr = pooled.bytes.ptr;
    var fallback = try pool.acquire();
    try std.testing.expect(pooled.pooled_index != null);
    try std.testing.expect(fallback.fallback_index != null);
    try std.testing.expectError(error.Exhausted, pool.acquire());
    try pool.release(&pooled);
    var reused = try pool.acquire();
    defer pool.release(&reused) catch unreachable;
    try std.testing.expectEqual(pooled_ptr, reused.bytes.ptr);
    try pool.release(&fallback);
}

test "packet buffer pools validate configurations and releases" {
    try std.testing.expectError(error.InvalidConfiguration, PacketBufferPool.init(std.testing.allocator, .{
        .packet_capacity = 0,
        .pooled_buffers = 1,
        .fallback_buffers = 0,
    }));
    var pool = try PacketBufferPool.init(std.testing.allocator, .{
        .packet_capacity = 1,
        .pooled_buffers = 1,
        .fallback_buffers = 0,
    });
    defer pool.deinit();
    var lease = try pool.acquire();
    var stale_lease = lease;
    try pool.release(&lease);
    try std.testing.expectError(error.InvalidRelease, pool.release(&stale_lease));
}
