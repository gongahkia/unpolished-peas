const std = @import("std");

pub const PayloadPoolError = std.mem.Allocator.Error || error{ InvalidConfiguration, PayloadTooLarge, PoolExhausted, InvalidLease };
pub const PayloadPoolPressure = struct { allocated_bytes: usize, byte_capacity: usize, in_use_slots: usize };

const Slot = struct { bytes: []u8 = &.{}, in_use: bool = false };

pub const Lease = struct {
    pool: *PayloadPool,
    slot: usize,
    bytes: []u8,

    pub fn release(self: *Lease) PayloadPoolError!void {
        try self.pool.release(self.slot);
        self.* = undefined;
    }
};

pub const PayloadPool = struct {
    allocator: std.mem.Allocator,
    byte_capacity: usize,
    allocated_bytes: usize = 0,
    slots: []Slot,

    pub fn init(allocator: std.mem.Allocator, slot_capacity: usize, byte_capacity: usize) PayloadPoolError!PayloadPool {
        if (slot_capacity == 0 or byte_capacity == 0) return error.InvalidConfiguration;
        const slots = try allocator.alloc(Slot, slot_capacity);
        for (slots) |*slot| slot.* = .{};
        return .{ .allocator = allocator, .byte_capacity = byte_capacity, .slots = slots };
    }

    pub fn deinit(self: *PayloadPool) void {
        for (self.slots) |slot| if (slot.bytes.len != 0) self.allocator.free(slot.bytes);
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    pub fn copy(self: *PayloadPool, input: []const u8) PayloadPoolError!Lease {
        if (input.len > self.byte_capacity) return error.PayloadTooLarge;
        var candidate: ?usize = null;
        for (self.slots, 0..) |slot, index| {
            if (slot.in_use) continue;
            if (slot.bytes.len >= input.len) {
                candidate = index;
                break;
            }
            if (candidate == null) candidate = index;
        }
        const index = candidate orelse return error.PoolExhausted;
        const slot = &self.slots[index];
        if (slot.bytes.len < input.len) {
            const retained = self.allocated_bytes - slot.bytes.len;
            if (input.len > self.byte_capacity - retained) return error.PoolExhausted;
            const bytes = try self.allocator.alloc(u8, input.len);
            if (slot.bytes.len != 0) self.allocator.free(slot.bytes);
            slot.bytes = bytes;
            self.allocated_bytes = retained + bytes.len;
        }
        slot.in_use = true;
        @memcpy(slot.bytes[0..input.len], input);
        return .{ .pool = self, .slot = index, .bytes = slot.bytes[0..input.len] };
    }

    pub fn inUse(self: *const PayloadPool) usize {
        var result: usize = 0;
        for (self.slots) |slot| {
            if (slot.in_use) result += 1;
        }
        return result;
    }

    pub fn pressure(self: *const PayloadPool) PayloadPoolPressure {
        return .{ .allocated_bytes = self.allocated_bytes, .byte_capacity = self.byte_capacity, .in_use_slots = self.inUse() };
    }

    fn release(self: *PayloadPool, index: usize) PayloadPoolError!void {
        if (index >= self.slots.len or !self.slots[index].in_use) return error.InvalidLease;
        self.slots[index].in_use = false;
    }
};

test "payload pools reuse bounded slots and report exhaustion" {
    var pool = try PayloadPool.init(std.testing.allocator, 1, 4);
    defer pool.deinit();
    var first = try pool.copy("data");
    try std.testing.expectError(error.PoolExhausted, pool.copy("x"));
    try first.release();
    var reused = try pool.copy("ok");
    defer reused.release() catch {};
    try std.testing.expectEqualStrings("ok", reused.bytes);
    try std.testing.expectEqual(@as(usize, 4), pool.allocated_bytes);
}
