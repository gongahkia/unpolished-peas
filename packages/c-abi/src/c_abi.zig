const core = @import("minna-san-core");
const runtime = @import("minna-san-runtime");
const std = @import("std");

pub const CAbiVersion = u32;
pub const CAbiHandle = opaque {};
pub const CVersion = extern struct {
    major: u16,
    minor: u16,
    patch: u16,
};
pub const CDurationNs = i64;
pub const CAddressFamily = enum(u8) {
    unspecified = 0,
    ipv4 = 4,
    ipv6 = 6,
};
pub const CAddress = extern struct {
    family: u8,
    bytes: [16]u8,
    port: u16,
};
pub const CBuffer = extern struct {
    data: [*c]u8,
    len: usize,
};
pub const CAllocateFn = *const fn (?*anyopaque, usize) callconv(.c) ?*anyopaque;
pub const CReleaseFn = *const fn (?*anyopaque, [*c]u8, usize) callconv(.c) void;
pub const CAllocator = extern struct {
    context: ?*anyopaque,
    allocate: ?CAllocateFn,
    release: ?CReleaseFn,
};
pub const CAllocatorError = error{ MissingAllocateCallback, AllocationFailed };
pub const CBufferReleaseError = error{ MissingReleaseCallback, InvalidBuffer };
pub const CEventKind = enum(u32) {
    connected = 1,
    disconnected = 2,
    message = 3,
    overflow = 4,
};
pub const CEvent = extern struct {
    kind: u32,
    mode: u32,
    sequence: u64,
    payload: CBuffer,
};
pub const c_abi_version: CAbiVersion = runtime.abi_version();

pub fn is_valid_buffer(buffer: CBuffer) bool {
    return buffer.data != null or buffer.len == 0;
}

pub fn allocate_buffer(allocator: CAllocator, len: usize) CAllocatorError!CBuffer {
    if (len == 0) return .{ .data = null, .len = 0 };
    const allocate = allocator.allocate orelse return error.MissingAllocateCallback;
    const data = allocate(allocator.context, len) orelse return error.AllocationFailed;
    return .{ .data = @ptrCast(data), .len = len };
}

pub fn release_buffer(allocator: CAllocator, buffer: CBuffer) CBufferReleaseError!void {
    if (!is_valid_buffer(buffer)) return error.InvalidBuffer;
    if (buffer.len == 0) return;
    const release = allocator.release orelse return error.MissingReleaseCallback;
    release(allocator.context, buffer.data, buffer.len);
}

pub export fn minna_san_abi_version() CAbiVersion {
    return c_abi_version;
}

pub export fn minna_san_abi_supports_version(requested_version: CAbiVersion) u8 {
    return @intFromBool(requested_version == c_abi_version);
}

pub const package_name = "c_abi";

comptime {
    _ = core.package_name;
    _ = runtime.package_name;
}

test "C ABI package boundary" {
    try std.testing.expectEqualStrings("c_abi", package_name);
}

test "C ABI exports its supported version" {
    try std.testing.expectEqual(runtime.abi_version(), minna_san_abi_version());
    try std.testing.expectEqual(@as(u8, 1), minna_san_abi_supports_version(c_abi_version));
}

test "C ABI rejects unsupported versions without exposing handle layout" {
    const handle: ?*CAbiHandle = null;
    try std.testing.expect(handle == null);
    try std.testing.expectEqual(@as(u8, 0), minna_san_abi_supports_version(c_abi_version + 1));
}

test "C ABI core declarations use C-safe layouts" {
    try std.testing.expectEqual(@as(usize, 6), @sizeOf(CVersion));
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(CAddress));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf([16]u8));
    try std.testing.expectEqual(@as(usize, @sizeOf(usize) * 2), @sizeOf(CBuffer));
    try std.testing.expectEqual(@as(usize, 16 + @sizeOf(CBuffer)), @sizeOf(CEvent));
}

test "C ABI buffer declarations reject null nonempty data" {
    try std.testing.expect(is_valid_buffer(.{ .data = null, .len = 0 }));
    try std.testing.expect(!is_valid_buffer(.{ .data = null, .len = 1 }));
}

test "C ABI allocator bridge preserves caller allocation and release" {
    const Callbacks = struct {
        var storage: [8]u8 = undefined;
        var released_len: usize = 0;

        fn allocate(_: ?*anyopaque, len: usize) callconv(.c) ?*anyopaque {
            if (len > storage.len) return null;
            return @ptrCast(&storage);
        }

        fn release(_: ?*anyopaque, _: [*c]u8, len: usize) callconv(.c) void {
            released_len = len;
        }
    };
    const allocator = CAllocator{ .context = null, .allocate = Callbacks.allocate, .release = Callbacks.release };
    const buffer = try allocate_buffer(allocator, 8);
    try release_buffer(allocator, buffer);
    try std.testing.expectEqual(@as(usize, 8), Callbacks.released_len);
}

test "C ABI allocator bridge rejects missing and failed callbacks" {
    const missing = CAllocator{ .context = null, .allocate = null, .release = null };
    try std.testing.expectEqual(@as(usize, 3 * @sizeOf(usize)), @sizeOf(CAllocator));
    try std.testing.expectEqual(@as(usize, 0), (try allocate_buffer(missing, 0)).len);
    try std.testing.expectError(error.MissingAllocateCallback, allocate_buffer(missing, 1));
    try std.testing.expectError(error.MissingReleaseCallback, release_buffer(missing, .{ .data = @ptrFromInt(1), .len = 1 }));
    try std.testing.expectError(error.InvalidBuffer, release_buffer(missing, .{ .data = null, .len = 1 }));
}
