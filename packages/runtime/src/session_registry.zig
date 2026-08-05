const std = @import("std");
const resource = @import("resource_handle.zig");
const lifecycle = @import("session_lifecycle.zig");

pub const SessionRegistryError = std.mem.Allocator.Error || resource.HandleError || lifecycle.SessionLifecycleError || error{ InvalidConfiguration, SessionCapacityExceeded, UnknownSession };
pub const SessionLifecycle = lifecycle.SessionLifecycle;
pub const SessionState = lifecycle.SessionState;
pub const SessionTransition = lifecycle.SessionTransition;

const Entry = struct {
    handle: *resource.ResourceHandle,
    lifecycle: lifecycle.SessionLifecycle = .{},
};

pub const SessionRegistry = struct {
    allocator: std.mem.Allocator,
    resources: *resource.ResourceRegistry,
    capacity: usize,
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator, resources: *resource.ResourceRegistry, capacity: usize) SessionRegistryError!SessionRegistry {
        if (capacity == 0 or capacity > resources.slots.len) return error.InvalidConfiguration;
        return .{ .allocator = allocator, .resources = resources, .capacity = capacity };
    }

    pub fn deinit(self: *SessionRegistry) void {
        for (self.entries.items) |entry| self.resources.release_kind(entry.handle, .session) catch {};
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn create(self: *SessionRegistry) SessionRegistryError!*resource.ResourceHandle {
        if (self.entries.items.len >= self.capacity) return error.SessionCapacityExceeded;
        const handle = try self.resources.acquire_kind(.session);
        errdefer self.resources.release_kind(handle, .session) catch {};
        try self.entries.append(self.allocator, .{ .handle = handle });
        return handle;
    }

    pub fn lookup(self: *SessionRegistry, handle: *resource.ResourceHandle) SessionRegistryError!*lifecycle.SessionLifecycle {
        try self.resources.validate_kind(handle, .session);
        for (self.entries.items) |*entry| if (entry.handle == handle) return &entry.lifecycle;
        return error.UnknownSession;
    }

    pub fn transition(self: *SessionRegistry, handle: *resource.ResourceHandle, action: lifecycle.SessionTransition) SessionRegistryError!void {
        const session = try self.lookup(handle);
        try session.transition(action);
    }

    pub fn close(self: *SessionRegistry, handle: *resource.ResourceHandle) SessionRegistryError!void {
        const lifecycle_value = try self.lookup(handle);
        switch (lifecycle_value.state) {
            .establishing, .ready => try lifecycle_value.transition(.begin_draining),
            .idle, .closed => {},
            .draining => try lifecycle_value.transition(.close),
        }
        if (lifecycle_value.state == .draining) try lifecycle_value.transition(.close);
        for (self.entries.items, 0..) |entry, index| {
            if (entry.handle != handle) continue;
            try self.resources.release_kind(handle, .session);
            _ = self.entries.orderedRemove(index);
            return;
        }
        return error.UnknownSession;
    }
};

test "session registries invalidate closed handles after slot reuse" {
    var resources = try resource.ResourceRegistry.init(std.testing.allocator, 1);
    defer resources.deinit();
    var sessions = try SessionRegistry.init(std.testing.allocator, &resources, 1);
    defer sessions.deinit();
    const first = try sessions.create();
    try sessions.transition(first, .begin_establishing);
    try sessions.transition(first, .mark_ready);
    try sessions.transition(first, .begin_draining);
    try sessions.close(first);
    try std.testing.expectError(error.StaleHandle, sessions.lookup(first));
    const second = try sessions.create();
    try std.testing.expect(first != second);
    try std.testing.expectError(error.StaleHandle, sessions.lookup(first));
    try sessions.transition(second, .begin_establishing);
    try std.testing.expectEqual(lifecycle.SessionState.establishing, (try sessions.lookup(second)).state);
}

test "session registries enforce configured capacity" {
    var resources = try resource.ResourceRegistry.init(std.testing.allocator, 2);
    defer resources.deinit();
    var sessions = try SessionRegistry.init(std.testing.allocator, &resources, 1);
    defer sessions.deinit();
    _ = try sessions.create();
    try std.testing.expectError(error.SessionCapacityExceeded, sessions.create());
    try std.testing.expectError(error.InvalidConfiguration, SessionRegistry.init(std.testing.allocator, &resources, 0));
}
