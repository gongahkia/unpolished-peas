const std = @import("std");

const Header = extern struct {
    payload_len: usize,
    total_len: usize,
};

const alignment = std.mem.Alignment.of(u128);

pub export fn up_stb_malloc(payload_len: usize) ?*anyopaque {
    if (payload_len == 0) return null;
    const total_len = std.math.add(usize, @sizeOf(Header), payload_len) catch return null;
    const bytes = std.heap.wasm_allocator.alignedAlloc(u8, alignment, total_len) catch return null;
    const header: *Header = @ptrCast(@alignCast(bytes.ptr));
    header.* = .{ .payload_len = payload_len, .total_len = total_len };
    return @ptrCast(bytes.ptr + @sizeOf(Header));
}

pub export fn up_stb_realloc(pointer: ?*anyopaque, payload_len: usize) ?*anyopaque {
    const old = pointer orelse return up_stb_malloc(payload_len);
    if (payload_len == 0) {
        up_stb_free(old);
        return null;
    }

    const old_header = headerFor(old);
    const next = up_stb_malloc(payload_len) orelse return null;
    const copy_len = @min(old_header.payload_len, payload_len);
    const source: [*]const u8 = @ptrCast(old);
    const destination: [*]u8 = @ptrCast(next);
    @memcpy(destination[0..copy_len], source[0..copy_len]);
    up_stb_free(old);
    return next;
}

pub export fn up_stb_free(pointer: ?*anyopaque) void {
    const value = pointer orelse return;
    const header = headerFor(value);
    const bytes: [*]align(@alignOf(u128)) u8 = @ptrCast(@alignCast(header));
    std.heap.wasm_allocator.free(bytes[0..header.total_len]);
}

fn headerFor(pointer: *anyopaque) *Header {
    const payload: [*]u8 = @ptrCast(pointer);
    const bytes: [*]align(@alignOf(u128)) u8 = @alignCast(payload - @sizeOf(Header));
    return @ptrCast(bytes);
}
