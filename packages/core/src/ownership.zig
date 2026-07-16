const std = @import("std");

pub const Ownership = enum {
    borrowed,
    owned,
};

pub const TransferError = error{BufferAlreadyTransferred};

pub const BorrowedBuffer = struct {
    bytes: []const u8,

    pub fn init(bytes: []const u8) BorrowedBuffer {
        return .{ .bytes = bytes };
    }

    pub fn ownership(_: BorrowedBuffer) Ownership {
        return .borrowed;
    }
};

pub const OwnedBuffer = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,

    pub fn initCopy(allocator: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error!OwnedBuffer {
        return .{ .allocator = allocator, .bytes = try allocator.dupe(u8, bytes) };
    }

    pub fn borrow(self: *const OwnedBuffer) BorrowedBuffer {
        return .init(self.bytes);
    }

    pub fn ownership(_: *const OwnedBuffer) Ownership {
        return .owned;
    }

    pub fn deinit(self: *OwnedBuffer) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const TransferredBuffer = struct {
    buffer: ?OwnedBuffer,

    pub fn init(buffer: OwnedBuffer) TransferredBuffer {
        return .{ .buffer = buffer };
    }

    pub fn into_owned(self: *TransferredBuffer) TransferError!OwnedBuffer {
        const buffer = self.buffer orelse return error.BufferAlreadyTransferred;
        self.buffer = null;
        return buffer;
    }

    pub fn deinit(self: *TransferredBuffer) void {
        if (self.buffer) |*buffer| buffer.deinit();
        self.* = undefined;
    }
};

test "owned buffers copy and release allocator-owned bytes" {
    var owned = try OwnedBuffer.initCopy(std.testing.allocator, "minna-san");
    defer owned.deinit();
    try std.testing.expectEqual(Ownership.owned, owned.ownership());
    try std.testing.expectEqualStrings("minna-san", owned.bytes);
    try std.testing.expectEqual(Ownership.borrowed, owned.borrow().ownership());
}

test "owned buffer allocation failure leaves no resource to release" {
    var storage: [1]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    try std.testing.expectError(error.OutOfMemory, OwnedBuffer.initCopy(fixed.allocator(), "xx"));
}

test "transferred buffers move ownership exactly once" {
    var transfer = TransferredBuffer.init(try OwnedBuffer.initCopy(std.testing.allocator, "transfer"));
    var owned = try transfer.into_owned();
    defer owned.deinit();
    try std.testing.expectError(error.BufferAlreadyTransferred, transfer.into_owned());
}
