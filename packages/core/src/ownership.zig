const std = @import("std");

pub const Ownership = enum { borrowed, owned, retained, transferred };
pub const BufferError = error{ BufferAlreadyReleased, AllocatorMismatch };
pub const TransferError = error{BufferAlreadyTransferred};

var released_storage: [0]u8 = .{};

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

    pub fn release(self: *OwnedBuffer) BufferError!void {
        if (self.is_released()) return error.BufferAlreadyReleased;
        self.allocator.free(self.bytes);
        self.bytes = released_storage[0..];
    }

    pub fn release_with(self: *OwnedBuffer, allocator: std.mem.Allocator) BufferError!void {
        if (self.is_released()) return error.BufferAlreadyReleased;
        if (!allocator_matches(self.allocator, allocator)) return error.AllocatorMismatch;
        try self.release();
    }

    pub fn into_transfer(self: *OwnedBuffer) TransferError!TransferredBuffer {
        if (self.is_released()) return error.BufferAlreadyTransferred;
        const buffer = self.*;
        self.bytes = released_storage[0..];
        return .{ .buffer = buffer };
    }

    pub fn deinit(self: *OwnedBuffer) void {
        self.release() catch {};
    }

    fn is_released(self: *const OwnedBuffer) bool {
        return self.bytes.ptr == released_storage[0..].ptr;
    }
};

pub const RetainedBuffer = struct {
    buffer: ?OwnedBuffer,

    pub fn initCopy(allocator: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error!RetainedBuffer {
        return .{ .buffer = try OwnedBuffer.initCopy(allocator, bytes) };
    }

    pub fn retain(allocator: std.mem.Allocator, borrowed: BorrowedBuffer) std.mem.Allocator.Error!RetainedBuffer {
        return initCopy(allocator, borrowed.bytes);
    }

    pub fn borrow(self: *const RetainedBuffer) BorrowedBuffer {
        return .init(if (self.buffer) |buffer| buffer.bytes else &.{});
    }

    pub fn ownership(_: *const RetainedBuffer) Ownership {
        return .retained;
    }

    pub fn release(self: *RetainedBuffer) BufferError!void {
        var buffer = self.buffer orelse return error.BufferAlreadyReleased;
        try buffer.release();
        self.buffer = null;
    }

    pub fn release_with(self: *RetainedBuffer, allocator: std.mem.Allocator) BufferError!void {
        var buffer = self.buffer orelse return error.BufferAlreadyReleased;
        try buffer.release_with(allocator);
        self.buffer = null;
    }

    pub fn into_transfer(self: *RetainedBuffer) TransferError!TransferredBuffer {
        const buffer = self.buffer orelse return error.BufferAlreadyTransferred;
        self.buffer = null;
        return .{ .buffer = buffer };
    }

    pub fn deinit(self: *RetainedBuffer) void {
        self.release() catch {};
    }
};

pub const TransferredBuffer = struct {
    buffer: ?OwnedBuffer,

    pub fn init(buffer: *OwnedBuffer) TransferError!TransferredBuffer {
        return buffer.into_transfer();
    }

    pub fn ownership(_: *const TransferredBuffer) Ownership {
        return .transferred;
    }

    pub fn into_owned(self: *TransferredBuffer) TransferError!OwnedBuffer {
        const buffer = self.buffer orelse return error.BufferAlreadyTransferred;
        self.buffer = null;
        return buffer;
    }

    pub fn deinit(self: *TransferredBuffer) void {
        if (self.buffer) |*buffer| buffer.deinit();
        self.buffer = null;
    }
};

fn allocator_matches(left: std.mem.Allocator, right: std.mem.Allocator) bool {
    return left.ptr == right.ptr and left.vtable == right.vtable;
}

test "owned retained and borrowed buffers preserve explicit ownership" {
    var owned = try OwnedBuffer.initCopy(std.testing.allocator, "minna-san");
    defer owned.deinit();
    var retained = try RetainedBuffer.retain(std.testing.allocator, owned.borrow());
    defer retained.deinit();
    try std.testing.expectEqual(Ownership.owned, owned.ownership());
    try std.testing.expectEqual(Ownership.borrowed, owned.borrow().ownership());
    try std.testing.expectEqual(Ownership.retained, retained.ownership());
    try std.testing.expectEqualStrings("minna-san", retained.borrow().bytes);
}

test "owned buffer allocation failure leaves no resource to release" {
    var storage: [1]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    try std.testing.expectError(error.OutOfMemory, OwnedBuffer.initCopy(fixed.allocator(), "xx"));
}

test "owned buffers reject double release and allocator misuse" {
    var owned = try OwnedBuffer.initCopy(std.testing.allocator, "owned");
    var storage: [8]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    try std.testing.expectError(error.AllocatorMismatch, owned.release_with(fixed.allocator()));
    try owned.release_with(std.testing.allocator);
    try std.testing.expectError(error.BufferAlreadyReleased, owned.release());
}

test "transferred buffers move ownership exactly once" {
    var owned = try OwnedBuffer.initCopy(std.testing.allocator, "transfer");
    var transfer = try TransferredBuffer.init(&owned);
    try std.testing.expectEqual(Ownership.transferred, transfer.ownership());
    var reclaimed = try transfer.into_owned();
    defer reclaimed.deinit();
    try std.testing.expectError(error.BufferAlreadyTransferred, transfer.into_owned());
    try std.testing.expectError(error.BufferAlreadyTransferred, owned.into_transfer());
}
