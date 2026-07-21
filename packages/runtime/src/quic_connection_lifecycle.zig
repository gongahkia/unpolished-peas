const std = @import("std");
const core = @import("minna-san-core");
const resource = @import("resource_handle.zig");
const session = @import("session_registry.zig");

pub const max_quic_connection_events: usize = core.max_event_capacity;

pub const QuicConnectionRole = enum(u8) {
    client,
    server,
};

pub const QuicConnectionEventKind = enum(u8) {
    connected,
    transport_shutdown,
    peer_shutdown,
    shutdown_complete,
    local_address_changed,
    peer_address_changed,
};

pub const QuicConnectionProviderEvent = extern struct {
    connection_id: u64,
    kind: u8,
    status: c_int = 0,

    pub fn eventKind(self: QuicConnectionProviderEvent) ?QuicConnectionEventKind {
        return std.meta.intToEnum(QuicConnectionEventKind, self.kind) catch null;
    }
};

pub const QuicConnectionCallback = *const fn (?*anyopaque, *const QuicConnectionProviderEvent) callconv(.c) c_int;

pub const QuicConnectionProviderVTable = extern struct {
    open: *const fn (?*anyopaque, u64, ?*anyopaque, QuicConnectionCallback) callconv(.c) c_int,
    shutdown: *const fn (?*anyopaque, u64) callconv(.c) void,
};

pub const QuicConnectionLifecycleConfig = struct {
    maximum_connections: usize = 64,
    maximum_events: usize = 64,

    pub fn validate(self: QuicConnectionLifecycleConfig) error{InvalidConfiguration}!void {
        if (self.maximum_connections == 0 or self.maximum_connections > core.max_session_capacity or self.maximum_events == 0 or self.maximum_events > max_quic_connection_events) return error.InvalidConfiguration;
    }
};

pub const QuicConnectionConfig = struct {
    role: QuicConnectionRole,
    idle_timeout_ns: ?core.TimeNs = null,
};

pub const QuicConnectionStatus = struct {
    role: QuicConnectionRole,
    state: session.SessionState,
    transport_status: ?c_int = null,
    local_address_changes: u32 = 0,
    peer_address_changes: u32 = 0,
};

pub const QuicConnectionLifecycleError = std.mem.Allocator.Error || resource.HandleError || session.SessionRegistryError || error{ InvalidConfiguration, ConnectionCapacityExceeded, UnknownConnection, ProviderFailed, ProviderEventQueueFull };

const Entry = struct {
    session_handle: *resource.ResourceHandle,
    connection_id: u64,
    config: QuicConnectionConfig,
    opened_at_ns: core.TimeNs,
    last_activity_ns: core.TimeNs,
    transport_status: ?c_int = null,
    local_address_changes: u32 = 0,
    peer_address_changes: u32 = 0,
};

pub const QuicConnectionLifecycle = struct {
    allocator: std.mem.Allocator,
    sessions: *session.SessionRegistry,
    config: QuicConnectionLifecycleConfig,
    context: ?*anyopaque,
    vtable: QuicConnectionProviderVTable,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    events: []QuicConnectionProviderEvent,
    event_start: usize = 0,
    event_count: usize = 0,
    event_mutex: std.Thread.Mutex = .{},
    next_connection_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator, sessions: *session.SessionRegistry, config: QuicConnectionLifecycleConfig, context: ?*anyopaque, vtable: QuicConnectionProviderVTable) QuicConnectionLifecycleError!QuicConnectionLifecycle {
        try config.validate();
        const events = try allocator.alloc(QuicConnectionProviderEvent, config.maximum_events);
        return .{ .allocator = allocator, .sessions = sessions, .config = config, .context = context, .vtable = vtable, .events = events };
    }

    pub fn deinit(self: *QuicConnectionLifecycle) void {
        self.entries.deinit(self.allocator);
        self.allocator.free(self.events);
        self.* = undefined;
    }

    pub fn connect(self: *QuicConnectionLifecycle, connection_config: QuicConnectionConfig, now_ns: core.TimeNs) QuicConnectionLifecycleError!*resource.ResourceHandle {
        if (self.entries.items.len == self.config.maximum_connections) return error.ConnectionCapacityExceeded;
        const session_handle = try self.sessions.create();
        errdefer self.sessions.close(session_handle) catch {};
        try self.sessions.transition(session_handle, .begin_establishing);
        const connection_id = self.nextConnectionId();
        try self.entries.append(self.allocator, .{ .session_handle = session_handle, .connection_id = connection_id, .config = connection_config, .opened_at_ns = now_ns, .last_activity_ns = now_ns });
        errdefer _ = self.entries.pop();
        if (self.vtable.open(self.context, connection_id, self, callback) != @intFromEnum(core.CResult.ok)) return error.ProviderFailed;
        return session_handle;
    }

    pub fn close(self: *QuicConnectionLifecycle, session_handle: *resource.ResourceHandle) QuicConnectionLifecycleError!void {
        const entry = try self.lookup(session_handle);
        const lifecycle = try self.sessions.lookup(session_handle);
        switch (lifecycle.state) {
            .establishing, .ready => try lifecycle.transition(.begin_draining),
            .draining => return,
            else => return error.UnknownConnection,
        }
        self.vtable.shutdown(self.context, entry.connection_id);
    }

    pub fn poll(self: *QuicConnectionLifecycle, now_ns: core.TimeNs, work_budget: usize) QuicConnectionLifecycleError!usize {
        if (work_budget == 0) return error.InvalidConfiguration;
        var work_completed: usize = 0;
        while (work_completed < work_budget) : (work_completed += 1) {
            const event = self.nextProviderEvent() orelse break;
            try self.applyEvent(event, now_ns);
        }
        if (work_completed < work_budget) work_completed += self.enforceIdleTimeouts(now_ns, work_budget - work_completed);
        return work_completed;
    }

    pub fn status(self: *QuicConnectionLifecycle, session_handle: *resource.ResourceHandle) QuicConnectionLifecycleError!QuicConnectionStatus {
        const entry = try self.lookup(session_handle);
        return .{
            .role = entry.config.role,
            .state = (try self.sessions.lookup(session_handle)).state,
            .transport_status = entry.transport_status,
            .local_address_changes = entry.local_address_changes,
            .peer_address_changes = entry.peer_address_changes,
        };
    }

    pub fn queuedProviderEvents(self: *QuicConnectionLifecycle) usize {
        self.event_mutex.lock();
        defer self.event_mutex.unlock();
        return self.event_count;
    }

    fn callback(context: ?*anyopaque, event: *const QuicConnectionProviderEvent) callconv(.c) c_int {
        const self: *QuicConnectionLifecycle = @ptrCast(@alignCast(context orelse return @intFromEnum(core.CResult.invalid_argument)));
        if (event.eventKind() == null) return @intFromEnum(core.CResult.invalid_argument);
        self.event_mutex.lock();
        defer self.event_mutex.unlock();
        if (self.event_count == self.config.maximum_events) return @intFromEnum(core.CResult.resource_exhausted);
        const index = (self.event_start + self.event_count) % self.config.maximum_events;
        self.events[index] = event.*;
        self.event_count += 1;
        return @intFromEnum(core.CResult.ok);
    }

    fn applyEvent(self: *QuicConnectionLifecycle, event: QuicConnectionProviderEvent, now_ns: core.TimeNs) QuicConnectionLifecycleError!void {
        const index = self.indexForConnection(event.connection_id) orelse return error.UnknownConnection;
        const entry = &self.entries.items[index];
        const lifecycle = try self.sessions.lookup(entry.session_handle);
        entry.last_activity_ns = now_ns;
        switch (event.eventKind().?) {
            .connected => if (lifecycle.state == .establishing) try lifecycle.transition(.mark_ready),
            .transport_shutdown => {
                entry.transport_status = event.status;
                if (lifecycle.state == .establishing or lifecycle.state == .ready) try lifecycle.transition(.begin_draining);
            },
            .peer_shutdown => if (lifecycle.state == .establishing or lifecycle.state == .ready) try lifecycle.transition(.begin_draining),
            .local_address_changed => entry.local_address_changes +%= 1,
            .peer_address_changed => entry.peer_address_changes +%= 1,
            .shutdown_complete => {
                if (lifecycle.state == .establishing or lifecycle.state == .ready) try lifecycle.transition(.begin_draining);
                try self.sessions.close(entry.session_handle);
                _ = self.entries.orderedRemove(index);
            },
        }
    }

    fn enforceIdleTimeouts(self: *QuicConnectionLifecycle, now_ns: core.TimeNs, work_budget: usize) usize {
        var work_completed: usize = 0;
        for (self.entries.items) |*entry| {
            if (work_completed == work_budget) break;
            const timeout_ns = entry.config.idle_timeout_ns orelse continue;
            const lifecycle = self.sessions.lookup(entry.session_handle) catch continue;
            if (lifecycle.state != .establishing and lifecycle.state != .ready) continue;
            const deadline = std.math.add(core.TimeNs, entry.last_activity_ns, timeout_ns) catch continue;
            if (now_ns < deadline) continue;
            lifecycle.transition(.begin_draining) catch continue;
            self.vtable.shutdown(self.context, entry.connection_id);
            work_completed += 1;
        }
        return work_completed;
    }

    fn nextProviderEvent(self: *QuicConnectionLifecycle) ?QuicConnectionProviderEvent {
        self.event_mutex.lock();
        defer self.event_mutex.unlock();
        if (self.event_count == 0) return null;
        const event = self.events[self.event_start];
        self.event_start = (self.event_start + 1) % self.config.maximum_events;
        self.event_count -= 1;
        return event;
    }

    fn lookup(self: *QuicConnectionLifecycle, session_handle: *resource.ResourceHandle) QuicConnectionLifecycleError!*Entry {
        _ = try self.sessions.lookup(session_handle);
        for (self.entries.items) |*entry| if (entry.session_handle == session_handle) return entry;
        return error.UnknownConnection;
    }

    fn indexForConnection(self: *const QuicConnectionLifecycle, connection_id: u64) ?usize {
        for (self.entries.items, 0..) |entry, index| if (entry.connection_id == connection_id) return index;
        return null;
    }

    fn nextConnectionId(self: *QuicConnectionLifecycle) u64 {
        const id = self.next_connection_id;
        self.next_connection_id +%= 1;
        if (self.next_connection_id == 0) self.next_connection_id = 1;
        return id;
    }
};

test "QUIC connection lifecycles map copied provider callbacks through explicit polls" {
    const FakeProvider = struct {
        callback_context: ?*anyopaque = null,
        callback_fn: ?QuicConnectionCallback = null,
        opens: usize = 0,
        shutdowns: usize = 0,

        fn open(context: ?*anyopaque, _: u64, callback_context: ?*anyopaque, callback_fn: QuicConnectionCallback) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.callback_context = callback_context;
            self.callback_fn = callback_fn;
            self.opens += 1;
            return @intFromEnum(core.CResult.ok);
        }

        fn shutdown(context: ?*anyopaque, connection_id: u64) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.shutdowns += 1;
            const complete = QuicConnectionProviderEvent{ .connection_id = connection_id, .kind = @intFromEnum(QuicConnectionEventKind.shutdown_complete) };
            _ = self.callback_fn.?(self.callback_context, &complete);
        }

        fn emit(self: *@This(), connection_id: u64, kind: QuicConnectionEventKind, status: c_int) c_int {
            const event = QuicConnectionProviderEvent{ .connection_id = connection_id, .kind = @intFromEnum(kind), .status = status };
            return self.callback_fn.?(self.callback_context, &event);
        }
    };

    var resources = try resource.ResourceRegistry.init(std.testing.allocator, 1);
    defer resources.deinit();
    var sessions = try session.SessionRegistry.init(std.testing.allocator, &resources, 1);
    defer sessions.deinit();
    var fake = FakeProvider{};
    var lifecycle = try QuicConnectionLifecycle.init(std.testing.allocator, &sessions, .{}, &fake, .{ .open = FakeProvider.open, .shutdown = FakeProvider.shutdown });
    defer lifecycle.deinit();
    const handle = try lifecycle.connect(.{ .role = .client, .idle_timeout_ns = 5 }, 0);
    try std.testing.expectEqual(@as(usize, 1), fake.opens);
    try std.testing.expectEqual(@intFromEnum(core.CResult.ok), fake.emit(1, .connected, 0));
    try std.testing.expectEqual(@as(usize, 1), try lifecycle.poll(0, 1));
    try std.testing.expectEqual(session.SessionState.ready, (try lifecycle.status(handle)).state);
    try std.testing.expectEqual(@intFromEnum(core.CResult.ok), fake.emit(1, .peer_address_changed, 0));
    try std.testing.expectEqual(@as(usize, 1), try lifecycle.poll(1, 1));
    try std.testing.expectEqual(@as(u32, 1), (try lifecycle.status(handle)).peer_address_changes);
    try std.testing.expectEqual(@as(usize, 1), try lifecycle.poll(6, 1));
    try std.testing.expectEqual(@as(usize, 1), fake.shutdowns);
    try std.testing.expectEqual(@as(usize, 1), try lifecycle.poll(6, 1));
    try std.testing.expectError(error.StaleHandle, sessions.lookup(handle));
}
