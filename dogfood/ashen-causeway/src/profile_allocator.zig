//! Developer-only allocator observation, following the existing render benchmark.
const std = @import("std");
pub const CountingAllocator = struct {
    parent: std.mem.Allocator,
    allocation_events: u64 = 0,
    allocated_bytes: u64 = 0,
    live_bytes: usize = 0,
    peak_bytes: usize = 0,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    pub fn init(parent: std.mem.Allocator) CountingAllocator {
        return .{ .parent = parent };
    }

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn reset(self: *CountingAllocator) void {
        self.allocation_events = 0;
        self.allocated_bytes = 0;
    }

    fn record(self: *CountingAllocator, bytes: usize) void {
        self.allocation_events +|= 1;
        self.allocated_bytes +|= bytes;
        self.live_bytes += bytes;
        self.peak_bytes = @max(self.peak_bytes, self.live_bytes);
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        const result = self.parent.rawAlloc(len, alignment, ret_addr);
        if (result != null) self.record(len);
        return result;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        const resized = self.parent.rawResize(memory, alignment, new_len, ret_addr);
        if (resized) {
            if (new_len > memory.len) self.record(new_len - memory.len) else self.live_bytes -= memory.len - new_len;
        }
        return resized;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        const result = self.parent.rawRemap(memory, alignment, new_len, ret_addr);
        if (result != null) {
            if (new_len > memory.len) self.record(new_len - memory.len) else self.live_bytes -= memory.len - new_len;
        }
        return result;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.live_bytes -= memory.len;
        self.parent.rawFree(memory, alignment, ret_addr);
    }
};
