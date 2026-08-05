const std = @import("std");
const transport = @import("minna-san-transport");
const resource = @import("resource_handle.zig");
const session = @import("session_registry.zig");

pub const TcpSessionRegistryError = std.mem.Allocator.Error || resource.HandleError || session.SessionRegistryError || transport.EndpointSelectionError || transport.TcpConnectionError || error{ InvalidConfiguration, InvalidRoute, SessionCapacityExceeded, UnknownSession };

pub const TcpDialConfig = struct {
    endpoint: transport.Endpoint,
    resolved: []const transport.ResolvedAddress = &.{},
    family_policy: transport.AddressFamilyPolicy = .prefer_ipv4,
    platform_support: transport.PlatformSupport,
    timeout_ms: u32,
};

pub const TcpSessionOutcome = enum {
    connecting,
    ready,
    refused,
    failed,
    timed_out,
    cancelled,
};

pub const TcpSessionPoll = struct {
    state: session.SessionState,
    outcome: TcpSessionOutcome,
    retryable: bool = false,
};

const Entry = struct {
    session: *resource.ResourceHandle,
    connection: transport.TcpConnection,
    route: transport.DialRoute,
};

pub const TcpSessionRegistry = struct {
    allocator: std.mem.Allocator,
    sessions: *session.SessionRegistry,
    capacity: usize,
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator, sessions: *session.SessionRegistry, capacity: usize) TcpSessionRegistryError!TcpSessionRegistry {
        if (capacity == 0 or capacity > sessions.capacity) return error.InvalidConfiguration;
        return .{ .allocator = allocator, .sessions = sessions, .capacity = capacity };
    }

    pub fn deinit(self: *TcpSessionRegistry) void {
        for (self.entries.items) |*entry| self.closeEntry(entry);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn dial(self: *TcpSessionRegistry, config: TcpDialConfig) TcpSessionRegistryError!*resource.ResourceHandle {
        if (config.timeout_ms == 0) return error.InvalidConfiguration;
        if (self.entries.items.len >= self.capacity) return error.SessionCapacityExceeded;
        const route = try transport.select_dial_route(config.endpoint, config.resolved, config.family_policy, config.platform_support);
        const peer = switch (route.address) {
            .ipv4 => |value| value,
            .ipv6 => return error.InvalidRoute,
        };
        const session_handle = try self.sessions.create();
        errdefer self.closeSession(session_handle);
        try self.sessions.transition(session_handle, .begin_establishing);
        var tcp_connection = try transport.TcpConnection.init();
        _ = tcp_connection.start_connect(peer, config.timeout_ms) catch |err| switch (err) {
            error.ConnectionRefused, error.ConnectFailed => transport.TcpConnectionState.failed,
            else => return err,
        };
        try self.entries.append(self.allocator, .{ .session = session_handle, .connection = tcp_connection, .route = route });
        return session_handle;
    }

    pub fn poll(self: *TcpSessionRegistry, handle: *resource.ResourceHandle, elapsed_ms: u32) TcpSessionRegistryError!TcpSessionPoll {
        const entry = try self.lookup(handle);
        const lifecycle = try self.sessions.lookup(handle);
        switch (lifecycle.state) {
            .establishing => {
                const connection_state = entry.connection.complete(elapsed_ms) catch |err| switch (err) {
                    error.ConnectionRefused => {
                        try lifecycle.transition(.begin_draining);
                        return .{ .state = lifecycle.state, .outcome = .refused, .retryable = true };
                    },
                    error.ConnectionFailed => {
                        try lifecycle.transition(.begin_draining);
                        return .{ .state = lifecycle.state, .outcome = .failed, .retryable = true };
                    },
                    error.TimedOut => {
                        try lifecycle.transition(.begin_draining);
                        return .{ .state = lifecycle.state, .outcome = .timed_out, .retryable = true };
                    },
                    error.Cancelled => {
                        try lifecycle.transition(.begin_draining);
                        return .{ .state = lifecycle.state, .outcome = .cancelled };
                    },
                    else => return err,
                };
                if (connection_state == .connecting) return .{ .state = lifecycle.state, .outcome = .connecting };
                try lifecycle.transition(.mark_ready);
                return .{ .state = lifecycle.state, .outcome = .ready };
            },
            .ready => return .{ .state = .ready, .outcome = .ready },
            .draining => return .{ .state = .draining, .outcome = outcome_for(entry.connection) },
            else => return error.InvalidState,
        }
    }

    pub fn cancel(self: *TcpSessionRegistry, handle: *resource.ResourceHandle) TcpSessionRegistryError!void {
        const entry = try self.lookup(handle);
        const lifecycle = try self.sessions.lookup(handle);
        if (lifecycle.state != .establishing) return error.InvalidState;
        try entry.connection.cancel();
        try lifecycle.transition(.begin_draining);
    }

    pub fn connection(self: *TcpSessionRegistry, handle: *resource.ResourceHandle) TcpSessionRegistryError!*transport.TcpConnection {
        return &(try self.lookup(handle)).connection;
    }

    pub fn adopt(self: *TcpSessionRegistry, accepted_connection: *transport.TcpConnection, peer: transport.Ipv4Address) TcpSessionRegistryError!*resource.ResourceHandle {
        if (self.entries.items.len >= self.capacity or accepted_connection.state != .connected) return error.InvalidConfiguration;
        const session_handle = try self.sessions.create();
        errdefer self.closeSession(session_handle);
        try self.sessions.transition(session_handle, .begin_establishing);
        try self.sessions.transition(session_handle, .mark_ready);
        try self.entries.append(self.allocator, .{ .session = session_handle, .connection = accepted_connection.*, .route = .{ .family = .ipv4, .address = .{ .ipv4 = peer } } });
        accepted_connection.* = undefined;
        return session_handle;
    }

    pub fn close(self: *TcpSessionRegistry, handle: *resource.ResourceHandle) TcpSessionRegistryError!void {
        _ = try self.lookup(handle);
        for (self.entries.items, 0..) |_, index| {
            if (self.entries.items[index].session != handle) continue;
            var entry = self.entries.orderedRemove(index);
            self.closeEntry(&entry);
            return;
        }
        return error.UnknownSession;
    }

    fn lookup(self: *TcpSessionRegistry, handle: *resource.ResourceHandle) TcpSessionRegistryError!*Entry {
        _ = try self.sessions.lookup(handle);
        for (self.entries.items) |*entry| if (entry.session == handle) return entry;
        return error.UnknownSession;
    }

    fn closeEntry(self: *TcpSessionRegistry, entry: *Entry) void {
        entry.connection.close();
        self.closeSession(entry.session);
    }

    fn closeSession(self: *TcpSessionRegistry, handle: *resource.ResourceHandle) void {
        const lifecycle = self.sessions.lookup(handle) catch return;
        switch (lifecycle.state) {
            .establishing, .ready => lifecycle.transition(.begin_draining) catch return,
            .draining => {},
            else => return,
        }
        self.sessions.close(handle) catch {};
    }
};

fn outcome_for(connection: transport.TcpConnection) TcpSessionOutcome {
    return switch (connection.state) {
        .failed => if (connection.failureReason() == .refused) .refused else .failed,
        .timed_out => .timed_out,
        .cancelled => .cancelled,
        .connected => .ready,
        else => .connecting,
    };
}

test "TCP session registries surface distinct refused and timed-out outcomes" {
    var resources = try resource.ResourceRegistry.init(std.testing.allocator, 2);
    defer resources.deinit();
    var sessions = try session.SessionRegistry.init(std.testing.allocator, &resources, 2);
    defer sessions.deinit();
    var registry = try TcpSessionRegistry.init(std.testing.allocator, &sessions, 2);
    defer registry.deinit();
    const refused = try sessions.create();
    try sessions.transition(refused, .begin_establishing);
    var refused_connection = try transport.TcpConnection.init();
    refused_connection.close();
    refused_connection.state = .failed;
    refused_connection.failure = .refused;
    try registry.entries.append(std.testing.allocator, .{ .session = refused, .connection = refused_connection, .route = .{ .family = .ipv4, .address = .{ .ipv4 = transport.Ipv4Address.wildcard(1) } } });
    const refused_poll = try registry.poll(refused, 0);
    try std.testing.expectEqual(TcpSessionOutcome.refused, refused_poll.outcome);
    try std.testing.expect(refused_poll.retryable);

    const timed_out = try sessions.create();
    try sessions.transition(timed_out, .begin_establishing);
    var timeout_connection = try transport.TcpConnection.init();
    timeout_connection.state = .connecting;
    timeout_connection.timeout_ms = 1;
    try registry.entries.append(std.testing.allocator, .{ .session = timed_out, .connection = timeout_connection, .route = .{ .family = .ipv4, .address = .{ .ipv4 = transport.Ipv4Address.wildcard(1) } } });
    const timeout_poll = try registry.poll(timed_out, 1);
    try std.testing.expectEqual(TcpSessionOutcome.timed_out, timeout_poll.outcome);
    try std.testing.expect(timeout_poll.retryable);
}
