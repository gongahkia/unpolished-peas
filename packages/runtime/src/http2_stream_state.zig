const std = @import("std");
const resource = @import("resource_handle.zig");

pub const Http2StreamError = std.mem.Allocator.Error || resource.HandleError || error{ InvalidConfiguration, StreamCapacityExceeded, DuplicateStreamId, UnknownStream, InvalidStreamId, InvalidTransition, InvalidPriority };
pub const Http2EndpointRole = enum { client, server };
pub const Http2StreamState = enum { idle, reserved_local, reserved_remote, open, half_closed_local, half_closed_remote, closed };
pub const Http2StreamTransition = enum { open_local, open_remote, reserve_local, reserve_remote, send_headers, receive_headers, send_data, receive_data, send_end_stream, receive_end_stream, reset, close };
pub const Http2StreamPriority = struct {
    dependency: u32 = 0,
    weight: u16 = 16,
    exclusive: bool = false,

    pub fn validate(self: Http2StreamPriority, stream_id: u32) Http2StreamError!void {
        if (self.weight == 0 or self.weight > 256 or self.dependency & 0x80000000 != 0 or self.dependency == stream_id) return error.InvalidPriority;
    }
};
pub const Http2StreamConfig = struct {
    role: Http2EndpointRole,
    maximum_streams: usize,

    pub fn validate(self: Http2StreamConfig) Http2StreamError!void {
        if (self.maximum_streams == 0) return error.InvalidConfiguration;
    }
};
pub const Http2StreamSnapshot = struct { handle: *resource.ResourceHandle, id: u32, state: Http2StreamState, priority: Http2StreamPriority };

const Entry = struct {
    handle: *resource.ResourceHandle,
    id: u32,
    state: Http2StreamState = .idle,
    priority: Http2StreamPriority,
};

pub const Http2StreamRegistry = struct {
    allocator: std.mem.Allocator,
    resources: *resource.ResourceRegistry,
    role: Http2EndpointRole,
    capacity: usize,
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator, resources: *resource.ResourceRegistry, config: Http2StreamConfig) Http2StreamError!Http2StreamRegistry {
        try config.validate();
        if (config.maximum_streams > resources.slots.len) return error.InvalidConfiguration;
        return .{ .allocator = allocator, .resources = resources, .role = config.role, .capacity = config.maximum_streams };
    }

    pub fn deinit(self: *Http2StreamRegistry) void {
        for (self.entries.items) |entry| self.resources.release_kind(entry.handle, .stream) catch {};
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn create(self: *Http2StreamRegistry, id: u32, opening: Http2StreamTransition, priority: Http2StreamPriority) Http2StreamError!*resource.ResourceHandle {
        if (self.entries.items.len == self.capacity) return error.StreamCapacityExceeded;
        try self.validateOpening(id, opening);
        try priority.validate(id);
        for (self.entries.items) |entry| if (entry.id == id) return error.DuplicateStreamId;
        const handle = try self.resources.acquire_kind(.stream);
        errdefer self.resources.release_kind(handle, .stream) catch {};
        try self.entries.append(self.allocator, .{ .handle = handle, .id = id, .state = stateAfter(.idle, opening) catch unreachable, .priority = priority });
        return handle;
    }

    pub fn transition(self: *Http2StreamRegistry, handle: *resource.ResourceHandle, action: Http2StreamTransition) Http2StreamError!Http2StreamState {
        const entry = try self.lookup(handle);
        entry.state = try stateAfter(entry.state, action);
        return entry.state;
    }

    pub fn setPriority(self: *Http2StreamRegistry, handle: *resource.ResourceHandle, priority: Http2StreamPriority) Http2StreamError!void {
        const entry = try self.lookup(handle);
        if (entry.state == .closed) return error.InvalidTransition;
        try priority.validate(entry.id);
        entry.priority = priority;
    }

    pub fn snapshot(self: *Http2StreamRegistry, handle: *resource.ResourceHandle) Http2StreamError!Http2StreamSnapshot {
        const entry = try self.lookup(handle);
        return .{ .handle = entry.handle, .id = entry.id, .state = entry.state, .priority = entry.priority };
    }

    pub fn close(self: *Http2StreamRegistry, handle: *resource.ResourceHandle) Http2StreamError!void {
        if ((try self.lookup(handle)).state != .closed) _ = try self.transition(handle, .close);
        for (self.entries.items, 0..) |entry, index| {
            if (entry.handle != handle) continue;
            try self.resources.release_kind(handle, .stream);
            _ = self.entries.orderedRemove(index);
            return;
        }
        return error.UnknownStream;
    }

    fn lookup(self: *Http2StreamRegistry, handle: *resource.ResourceHandle) Http2StreamError!*Entry {
        try self.resources.validate_kind(handle, .stream);
        for (self.entries.items) |*entry| if (entry.handle == handle) return entry;
        return error.UnknownStream;
    }

    fn validateOpening(self: Http2StreamRegistry, id: u32, action: Http2StreamTransition) Http2StreamError!void {
        if (id == 0 or id & 0x80000000 != 0) return error.InvalidStreamId;
        const local = switch (self.role) {
            .client => id & 1 == 1,
            .server => id & 1 == 0,
        };
        if ((action == .open_local or action == .reserve_local) != local) return error.InvalidStreamId;
        if ((action == .open_remote or action == .reserve_remote) == local) return error.InvalidStreamId;
    }
};

fn stateAfter(state: Http2StreamState, action: Http2StreamTransition) Http2StreamError!Http2StreamState {
    return switch (state) {
        .idle => switch (action) {
            .open_local, .open_remote => .open,
            .reserve_local => .reserved_local,
            .reserve_remote => .reserved_remote,
            else => error.InvalidTransition,
        },
        .reserved_local => switch (action) {
            .send_headers => .half_closed_remote,
            .reset, .close => .closed,
            else => error.InvalidTransition,
        },
        .reserved_remote => switch (action) {
            .receive_headers => .half_closed_local,
            .reset, .close => .closed,
            else => error.InvalidTransition,
        },
        .open => switch (action) {
            .send_headers, .receive_headers, .send_data, .receive_data => .open,
            .send_end_stream => .half_closed_local,
            .receive_end_stream => .half_closed_remote,
            .reset, .close => .closed,
            else => error.InvalidTransition,
        },
        .half_closed_local => switch (action) {
            .receive_headers, .receive_data => .half_closed_local,
            .receive_end_stream, .reset, .close => .closed,
            else => error.InvalidTransition,
        },
        .half_closed_remote => switch (action) {
            .send_headers, .send_data => .half_closed_remote,
            .send_end_stream, .reset, .close => .closed,
            else => error.InvalidTransition,
        },
        .closed => error.InvalidTransition,
    };
}

test "HTTP2 stream registries reject illegal transitions and retain resource-backed priorities" {
    var resources = try resource.ResourceRegistry.init(std.testing.allocator, 3);
    defer resources.deinit();
    var streams = try Http2StreamRegistry.init(std.testing.allocator, &resources, .{ .role = .client, .maximum_streams = 3 });
    defer streams.deinit();
    const stream = try streams.create(1, .open_local, .{ .dependency = 0, .weight = 32 });
    try std.testing.expectEqual(Http2StreamState.half_closed_local, try streams.transition(stream, .send_end_stream));
    try std.testing.expectError(error.InvalidTransition, streams.transition(stream, .send_data));
    try std.testing.expectEqual(Http2StreamState.closed, try streams.transition(stream, .receive_end_stream));
    try std.testing.expectError(error.InvalidTransition, streams.transition(stream, .receive_data));
    try std.testing.expectError(error.InvalidStreamId, streams.create(2, .open_local, .{}));
    const remote = try streams.create(2, .open_remote, .{});
    try streams.setPriority(remote, .{ .dependency = 0, .weight = 256, .exclusive = true });
    try std.testing.expectEqual(@as(u16, 256), (try streams.snapshot(remote)).priority.weight);
    try std.testing.expectError(error.InvalidPriority, streams.setPriority(remote, .{ .dependency = 2 }));
}
