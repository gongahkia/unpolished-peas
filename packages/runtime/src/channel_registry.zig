const std = @import("std");
const resource = @import("resource_handle.zig");
const session = @import("session_registry.zig");
const delivery = @import("channel_delivery.zig");

pub const ChannelRegistryError = std.mem.Allocator.Error || resource.HandleError || session.SessionRegistryError || delivery.ChannelDeliveryError || error{ InvalidConfiguration, ChannelCapacityExceeded, UnknownChannel, QueueFull };

pub const QueuedMessage = struct {
    channel: *resource.ResourceHandle,
    payload: []u8,

    pub fn deinit(self: *QueuedMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
        self.* = undefined;
    }
};

const Entry = struct {
    handle: *resource.ResourceHandle,
    session: *resource.ResourceHandle,
    descriptor: delivery.ChannelDescriptor,
    queue: std.ArrayListUnmanaged([]u8) = .empty,

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        for (self.queue.items) |payload| allocator.free(payload);
        self.queue.deinit(allocator);
        self.* = undefined;
    }
};

pub const ChannelRegistry = struct {
    allocator: std.mem.Allocator,
    resources: *resource.ResourceRegistry,
    sessions: *session.SessionRegistry,
    capacity: usize,
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator, resources: *resource.ResourceRegistry, sessions: *session.SessionRegistry, capacity: usize) ChannelRegistryError!ChannelRegistry {
        if (capacity == 0 or capacity > resources.slots.len) return error.InvalidConfiguration;
        return .{ .allocator = allocator, .resources = resources, .sessions = sessions, .capacity = capacity };
    }

    pub fn deinit(self: *ChannelRegistry) void {
        for (self.entries.items) |*entry| {
            entry.deinit(self.allocator);
            self.resources.release_kind(entry.handle, .channel) catch {};
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn create(self: *ChannelRegistry, owner: *resource.ResourceHandle, descriptor: delivery.ChannelDescriptor) ChannelRegistryError!*resource.ResourceHandle {
        _ = try self.sessions.lookup(owner);
        try descriptor.validate();
        if (self.entries.items.len >= self.capacity) return error.ChannelCapacityExceeded;
        const handle = try self.resources.acquire_kind(.channel);
        errdefer self.resources.release_kind(handle, .channel) catch {};
        try self.entries.append(self.allocator, .{ .handle = handle, .session = owner, .descriptor = descriptor });
        return handle;
    }

    pub fn enqueue(self: *ChannelRegistry, handle: *resource.ResourceHandle, payload: []const u8) ChannelRegistryError!void {
        const entry = try self.lookup(handle);
        try entry.descriptor.validate_payload(payload.len);
        if (entry.queue.items.len >= entry.descriptor.maximum_in_flight) return error.QueueFull;
        try entry.queue.append(self.allocator, try self.allocator.dupe(u8, payload));
    }

    pub fn dequeue(self: *ChannelRegistry, owner: *resource.ResourceHandle) ChannelRegistryError!?QueuedMessage {
        _ = try self.sessions.lookup(owner);
        var selected: ?usize = null;
        for (self.entries.items, 0..) |entry, index| {
            if (entry.session != owner or entry.queue.items.len == 0) continue;
            if (selected == null or entry.descriptor.priority > self.entries.items[selected.?].descriptor.priority) selected = index;
        }
        const index = selected orelse return null;
        const entry = &self.entries.items[index];
        return .{ .channel = entry.handle, .payload = entry.queue.orderedRemove(0) };
    }

    pub fn teardown(self: *ChannelRegistry, handle: *resource.ResourceHandle) ChannelRegistryError!void {
        try self.resources.validate_kind(handle, .channel);
        for (self.entries.items, 0..) |_, index| {
            if (self.entries.items[index].handle != handle) continue;
            var entry = self.entries.orderedRemove(index);
            entry.deinit(self.allocator);
            try self.resources.release_kind(handle, .channel);
            return;
        }
        return error.UnknownChannel;
    }

    pub fn queued(self: *ChannelRegistry, handle: *resource.ResourceHandle) ChannelRegistryError!usize {
        return (try self.lookup(handle)).queue.items.len;
    }

    fn lookup(self: *ChannelRegistry, handle: *resource.ResourceHandle) ChannelRegistryError!*Entry {
        try self.resources.validate_kind(handle, .channel);
        for (self.entries.items) |*entry| if (entry.handle == handle) return entry;
        return error.UnknownChannel;
    }
};

test "channel registries dequeue by priority and reject queue overflow deterministically" {
    var resources = try resource.ResourceRegistry.init(std.testing.allocator, 3);
    defer resources.deinit();
    var sessions = try session.SessionRegistry.init(std.testing.allocator, &resources, 1);
    defer sessions.deinit();
    const owner = try sessions.create();
    var channels = try ChannelRegistry.init(std.testing.allocator, &resources, &sessions, 2);
    defer channels.deinit();
    const low = try channels.create(owner, .{ .delivery = .datagram, .priority = 1, .maximum_payload_bytes = 4, .maximum_in_flight = 1 });
    const high = try channels.create(owner, .{ .delivery = .datagram, .priority = 2, .maximum_payload_bytes = 4, .maximum_in_flight = 1 });
    try channels.enqueue(low, "low");
    try channels.enqueue(high, "high");
    try std.testing.expectError(error.QueueFull, channels.enqueue(high, "next"));
    var first = (try channels.dequeue(owner)).?;
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(high, first.channel);
    try std.testing.expectEqualStrings("high", first.payload);
    var second = (try channels.dequeue(owner)).?;
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(low, second.channel);
    try std.testing.expectEqualStrings("low", second.payload);
    try std.testing.expect((try channels.dequeue(owner)) == null);
}

test "channel registries release queued payloads and handles on teardown" {
    var resources = try resource.ResourceRegistry.init(std.testing.allocator, 2);
    defer resources.deinit();
    var sessions = try session.SessionRegistry.init(std.testing.allocator, &resources, 1);
    defer sessions.deinit();
    const owner = try sessions.create();
    var channels = try ChannelRegistry.init(std.testing.allocator, &resources, &sessions, 1);
    defer channels.deinit();
    const handle = try channels.create(owner, .{ .delivery = .datagram, .maximum_payload_bytes = 4, .maximum_in_flight = 1 });
    try channels.enqueue(handle, "data");
    try channels.teardown(handle);
    try std.testing.expectError(error.StaleHandle, channels.queued(handle));
}
