const std = @import("std");
const core = @import("minna-san-core");
const transport = @import("minna-san-transport");
const resource = @import("resource_handle.zig");
const session = @import("session_registry.zig");
const connections = @import("quic_connection_lifecycle.zig");

pub const max_quic_migration_events: usize = core.max_event_capacity;

pub const QuicPathValidationEventKind = enum(u8) {
    validated,
    rejected,
};

pub const QuicPathValidationProviderEvent = extern struct {
    connection_id: u64,
    validation_id: u64,
    kind: u8,
    reserved: [3]u8 = [_]u8{0} ** 3,
    status: c_int = 0,

    pub fn eventKind(self: QuicPathValidationProviderEvent) ?QuicPathValidationEventKind {
        if (!std.mem.allEqual(u8, self.reserved[0..], 0)) return null;
        return std.meta.intToEnum(QuicPathValidationEventKind, self.kind) catch null;
    }
};

pub const QuicPathValidationCallback = *const fn (?*anyopaque, *const QuicPathValidationProviderEvent) callconv(.c) c_int;

pub const QuicMigrationProviderVTable = extern struct {
    validate_path: *const fn (?*anyopaque, u64, u64, *const transport.Endpoint, ?*anyopaque, QuicPathValidationCallback) callconv(.c) c_int,
};

pub const QuicMigrationPolicy = struct {
    allow_port_rebinding: bool = true,
    allow_address_change: bool = false,
};

pub const QuicMigrationPolicyConfig = struct {
    maximum_migrations: usize = 64,
    maximum_events: usize = 64,
    policy: QuicMigrationPolicy = .{},

    pub fn validate(self: QuicMigrationPolicyConfig) error{InvalidConfiguration}!void {
        if (self.maximum_migrations == 0 or self.maximum_migrations > core.max_session_capacity or self.maximum_events == 0 or self.maximum_events > max_quic_migration_events) return error.InvalidConfiguration;
    }
};

pub const QuicMigrationDecision = enum(u8) {
    validation_started,
    migrated,
    rejected_by_policy,
    rejected_by_provider,
    provider_failed,
};

pub const QuicMigrationReason = enum(u8) {
    port_rebinding,
    address_change,
    port_rebinding_not_permitted,
    address_change_not_permitted,
    provider_rejected,
    provider_failed,
};

pub const QuicMigrationSecurityAttribution = struct {
    sequence: u64,
    session: *resource.ResourceHandle,
    connection_id: u64,
    previous_endpoint: transport.Endpoint,
    candidate_endpoint: transport.Endpoint,
    decision: QuicMigrationDecision,
    reason: QuicMigrationReason,
    transport_status: ?c_int = null,
};

pub const QuicMigrationSnapshot = struct {
    session: *resource.ResourceHandle,
    connection_id: u64,
    current_endpoint: transport.Endpoint,
    pending_endpoint: ?transport.Endpoint,
    successful_migrations: u32,
};

pub const QuicMigrationPolicyError = std.mem.Allocator.Error || resource.HandleError || connections.QuicConnectionLifecycleError || error{ InvalidConfiguration, MigrationCapacityExceeded, AlreadyRegistered, UnknownSession, ConnectionNotReady, InvalidEndpoint, CandidateUnchanged, MigrationPending, PortRebindingDisallowed, AddressChangeDisallowed, ProviderFailed, ProviderEventQueueFull, UnknownValidation, AttributionOutputTooSmall, SequenceExhausted };

const PendingMigration = struct {
    id: u64,
    candidate: transport.Endpoint,
    reason: QuicMigrationReason,
};

const Entry = struct {
    session_handle: *resource.ResourceHandle,
    connection_id: u64,
    current_endpoint: transport.Endpoint,
    pending: ?PendingMigration = null,
    next_validation_id: u64 = 1,
    successful_migrations: u32 = 0,
};

pub const QuicMigrationPolicyRegistry = struct {
    allocator: std.mem.Allocator,
    connections: *connections.QuicConnectionLifecycle,
    config: QuicMigrationPolicyConfig,
    context: ?*anyopaque,
    vtable: QuicMigrationProviderVTable,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    events: []QuicPathValidationProviderEvent,
    event_start: usize = 0,
    event_count: usize = 0,
    event_mutex: std.Thread.Mutex = .{},
    attributions: []QuicMigrationSecurityAttribution,
    attribution_start: usize = 0,
    attribution_count: usize = 0,
    next_sequence: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, lifecycle: *connections.QuicConnectionLifecycle, config: QuicMigrationPolicyConfig, context: ?*anyopaque, vtable: QuicMigrationProviderVTable) QuicMigrationPolicyError!QuicMigrationPolicyRegistry {
        try config.validate();
        const events = try allocator.alloc(QuicPathValidationProviderEvent, config.maximum_events);
        errdefer allocator.free(events);
        const attributions = try allocator.alloc(QuicMigrationSecurityAttribution, config.maximum_events);
        return .{ .allocator = allocator, .connections = lifecycle, .config = config, .context = context, .vtable = vtable, .events = events, .attributions = attributions };
    }

    pub fn deinit(self: *QuicMigrationPolicyRegistry) void {
        self.entries.deinit(self.allocator);
        self.allocator.free(self.events);
        self.allocator.free(self.attributions);
        self.* = undefined;
    }

    pub fn register(self: *QuicMigrationPolicyRegistry, session_handle: *resource.ResourceHandle, current_endpoint: transport.Endpoint) QuicMigrationPolicyError!void {
        if (!current_endpoint.is_valid()) return error.InvalidEndpoint;
        if (self.entries.items.len == self.config.maximum_migrations) return error.MigrationCapacityExceeded;
        for (self.entries.items) |entry| if (entry.session_handle == session_handle) return error.AlreadyRegistered;
        const status = try self.connections.status(session_handle);
        if (status.state != .ready) return error.ConnectionNotReady;
        try self.entries.append(self.allocator, .{
            .session_handle = session_handle,
            .connection_id = try self.connections.connectionId(session_handle),
            .current_endpoint = current_endpoint,
        });
    }

    pub fn migrate(self: *QuicMigrationPolicyRegistry, session_handle: *resource.ResourceHandle, candidate_endpoint: transport.Endpoint) QuicMigrationPolicyError!u64 {
        if (!candidate_endpoint.is_valid()) return error.InvalidEndpoint;
        const entry = try self.lookup(session_handle);
        if ((try self.connections.status(session_handle)).state != .ready) return error.ConnectionNotReady;
        if (entry.pending != null) return error.MigrationPending;
        if (entry.current_endpoint.eql(candidate_endpoint)) return error.CandidateUnchanged;
        const reason = migrationReason(entry.current_endpoint, candidate_endpoint);
        switch (reason) {
            .port_rebinding => if (!self.config.policy.allow_port_rebinding) {
                _ = try self.record(entry, candidate_endpoint, .rejected_by_policy, .port_rebinding_not_permitted, null);
                return error.PortRebindingDisallowed;
            },
            .address_change => if (!self.config.policy.allow_address_change) {
                _ = try self.record(entry, candidate_endpoint, .rejected_by_policy, .address_change_not_permitted, null);
                return error.AddressChangeDisallowed;
            },
            else => unreachable,
        }
        const validation_id = entry.next_validation_id;
        entry.next_validation_id +%= 1;
        if (entry.next_validation_id == 0) entry.next_validation_id = 1;
        entry.pending = .{ .id = validation_id, .candidate = candidate_endpoint, .reason = reason };
        _ = try self.record(entry, candidate_endpoint, .validation_started, reason, null);
        if (self.vtable.validate_path(self.context, entry.connection_id, validation_id, &candidate_endpoint, self, callback) != @intFromEnum(core.CResult.ok)) {
            entry.pending = null;
            _ = try self.record(entry, candidate_endpoint, .provider_failed, .provider_failed, null);
            return error.ProviderFailed;
        }
        return validation_id;
    }

    pub fn poll(self: *QuicMigrationPolicyRegistry, work_budget: usize) QuicMigrationPolicyError!usize {
        if (work_budget == 0) return error.InvalidConfiguration;
        var work_completed: usize = 0;
        while (work_completed < work_budget) : (work_completed += 1) {
            const event = self.nextProviderEvent() orelse break;
            try self.applyEvent(event);
        }
        return work_completed;
    }

    pub fn snapshot(self: *QuicMigrationPolicyRegistry, session_handle: *resource.ResourceHandle) QuicMigrationPolicyError!QuicMigrationSnapshot {
        const entry = try self.lookup(session_handle);
        return .{
            .session = entry.session_handle,
            .connection_id = entry.connection_id,
            .current_endpoint = entry.current_endpoint,
            .pending_endpoint = if (entry.pending) |pending| pending.candidate else null,
            .successful_migrations = entry.successful_migrations,
        };
    }

    pub fn listSecurityAttributions(self: *QuicMigrationPolicyRegistry, output: []QuicMigrationSecurityAttribution) QuicMigrationPolicyError!usize {
        if (output.len < self.attribution_count) return error.AttributionOutputTooSmall;
        for (0..self.attribution_count) |index| output[index] = self.attributions[(self.attribution_start + index) % self.config.maximum_events];
        return self.attribution_count;
    }

    pub fn queuedProviderEvents(self: *QuicMigrationPolicyRegistry) usize {
        self.event_mutex.lock();
        defer self.event_mutex.unlock();
        return self.event_count;
    }

    fn callback(context: ?*anyopaque, event: *const QuicPathValidationProviderEvent) callconv(.c) c_int {
        const self: *QuicMigrationPolicyRegistry = @ptrCast(@alignCast(context orelse return @intFromEnum(core.CResult.invalid_argument)));
        if (event.eventKind() == null) return @intFromEnum(core.CResult.invalid_argument);
        self.event_mutex.lock();
        defer self.event_mutex.unlock();
        if (self.event_count == self.config.maximum_events) return @intFromEnum(core.CResult.resource_exhausted);
        const index = (self.event_start + self.event_count) % self.config.maximum_events;
        self.events[index] = event.*;
        self.event_count += 1;
        return @intFromEnum(core.CResult.ok);
    }

    fn applyEvent(self: *QuicMigrationPolicyRegistry, event: QuicPathValidationProviderEvent) QuicMigrationPolicyError!void {
        const entry = self.entryForConnection(event.connection_id) orelse return error.UnknownValidation;
        const pending = entry.pending orelse return error.UnknownValidation;
        if (pending.id != event.validation_id) return error.UnknownValidation;
        if ((try self.connections.status(entry.session_handle)).state != .ready) return error.ConnectionNotReady;
        switch (event.eventKind().?) {
            .validated => {
                entry.current_endpoint = pending.candidate;
                entry.pending = null;
                entry.successful_migrations +%= 1;
                _ = try self.record(entry, pending.candidate, .migrated, pending.reason, event.status);
            },
            .rejected => {
                entry.pending = null;
                _ = try self.record(entry, pending.candidate, .rejected_by_provider, .provider_rejected, event.status);
            },
        }
    }

    fn lookup(self: *QuicMigrationPolicyRegistry, session_handle: *resource.ResourceHandle) QuicMigrationPolicyError!*Entry {
        for (self.entries.items) |*entry| if (entry.session_handle == session_handle) return entry;
        return error.UnknownSession;
    }

    fn entryForConnection(self: *QuicMigrationPolicyRegistry, connection_id: u64) ?*Entry {
        for (self.entries.items) |*entry| if (entry.connection_id == connection_id) return entry;
        return null;
    }

    fn nextProviderEvent(self: *QuicMigrationPolicyRegistry) ?QuicPathValidationProviderEvent {
        self.event_mutex.lock();
        defer self.event_mutex.unlock();
        if (self.event_count == 0) return null;
        const event = self.events[self.event_start];
        self.event_start = (self.event_start + 1) % self.config.maximum_events;
        self.event_count -= 1;
        return event;
    }

    fn record(self: *QuicMigrationPolicyRegistry, entry: *const Entry, candidate_endpoint: transport.Endpoint, decision: QuicMigrationDecision, reason: QuicMigrationReason, transport_status: ?c_int) QuicMigrationPolicyError!QuicMigrationSecurityAttribution {
        if (self.next_sequence == std.math.maxInt(u64)) return error.SequenceExhausted;
        const attribution = QuicMigrationSecurityAttribution{
            .sequence = self.next_sequence,
            .session = entry.session_handle,
            .connection_id = entry.connection_id,
            .previous_endpoint = entry.current_endpoint,
            .candidate_endpoint = candidate_endpoint,
            .decision = decision,
            .reason = reason,
            .transport_status = transport_status,
        };
        self.next_sequence += 1;
        if (self.attribution_count < self.config.maximum_events) {
            self.attributions[(self.attribution_start + self.attribution_count) % self.config.maximum_events] = attribution;
            self.attribution_count += 1;
        } else {
            self.attributions[self.attribution_start] = attribution;
            self.attribution_start = (self.attribution_start + 1) % self.config.maximum_events;
        }
        return attribution;
    }
};

fn migrationReason(current: transport.Endpoint, candidate: transport.Endpoint) QuicMigrationReason {
    return if (sameAddress(current, candidate)) .port_rebinding else .address_change;
}

fn sameAddress(left: transport.Endpoint, right: transport.Endpoint) bool {
    if (left.kind != right.kind or left.scope_id != right.scope_id) return false;
    return switch (left.kind) {
        .ipv4 => std.mem.eql(u8, left.address[0..4], right.address[0..4]),
        .ipv6 => std.mem.eql(u8, left.address[0..], right.address[0..]),
        .dns, .provider => left.name_len == right.name_len and std.mem.eql(u8, left.name[0..left.name_len], right.name[0..right.name_len]),
    };
}

test "QUIC migration preserves a ready session through loopback UDP port rebinding" {
    const FakeConnectionProvider = struct {
        callback_context: ?*anyopaque = null,
        callback_fn: ?connections.QuicConnectionCallback = null,

        fn open(context: ?*anyopaque, _: u64, _: connections.QuicConnectionRole, callback_context: ?*anyopaque, callback_fn: connections.QuicConnectionCallback) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.callback_context = callback_context;
            self.callback_fn = callback_fn;
            return @intFromEnum(core.CResult.ok);
        }

        fn shutdown(_: ?*anyopaque, _: u64) callconv(.c) void {}

        fn connected(self: *@This(), connection_id: u64) c_int {
            const event = connections.QuicConnectionProviderEvent{ .connection_id = connection_id, .kind = @intFromEnum(connections.QuicConnectionEventKind.connected) };
            return self.callback_fn.?(self.callback_context, &event);
        }
    };
    const FakeMigrationProvider = struct {
        callback_context: ?*anyopaque = null,
        callback_fn: ?QuicPathValidationCallback = null,
        validations: usize = 0,
        connection_id: u64 = 0,
        validation_id: u64 = 0,
        candidate: ?transport.Endpoint = null,

        fn validatePath(context: ?*anyopaque, connection_id: u64, validation_id: u64, candidate: *const transport.Endpoint, callback_context: ?*anyopaque, callback_fn: QuicPathValidationCallback) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.callback_context = callback_context;
            self.callback_fn = callback_fn;
            self.validations += 1;
            self.connection_id = connection_id;
            self.validation_id = validation_id;
            self.candidate = candidate.*;
            return @intFromEnum(core.CResult.ok);
        }

        fn emit(self: *@This(), kind: QuicPathValidationEventKind, status: c_int) c_int {
            const event = QuicPathValidationProviderEvent{ .connection_id = self.connection_id, .validation_id = self.validation_id, .kind = @intFromEnum(kind), .status = status };
            return self.callback_fn.?(self.callback_context, &event);
        }
    };

    var server = try transport.UdpSocket.init(.{});
    defer server.close();
    try server.bind(transport.Ipv4Address.wildcard(0));
    const destination = try transport.Ipv4Address.parse("127.0.0.1", (try localAddress(&server)).port);
    var first_client = try transport.UdpSocket.init(.{});
    defer first_client.close();
    try first_client.bind(transport.Ipv4Address.wildcard(0));
    _ = try first_client.send_to("first", destination);
    var storage: [transport.max_ipv4_datagram_bytes]u8 = undefined;
    const first_source = (try receiveWithRetry(&server, storage[0..])).source;
    var second_client = try transport.UdpSocket.init(.{});
    defer second_client.close();
    try second_client.bind(transport.Ipv4Address.wildcard(0));
    _ = try second_client.send_to("second", destination);
    const second_source = (try receiveWithRetry(&server, storage[0..])).source;
    try std.testing.expect(first_source.port != second_source.port);

    var resources = try resource.ResourceRegistry.init(std.testing.allocator, 1);
    defer resources.deinit();
    var sessions = try session.SessionRegistry.init(std.testing.allocator, &resources, 1);
    defer sessions.deinit();
    var connection_provider = FakeConnectionProvider{};
    var lifecycle = try connections.QuicConnectionLifecycle.init(std.testing.allocator, &sessions, .{}, &connection_provider, .{ .open = FakeConnectionProvider.open, .shutdown = FakeConnectionProvider.shutdown });
    defer lifecycle.deinit();
    const handle = try lifecycle.connect(.{ .role = .client }, 0);
    try std.testing.expectEqual(@intFromEnum(core.CResult.ok), connection_provider.connected(try lifecycle.connectionId(handle)));
    try std.testing.expectEqual(@as(usize, 1), try lifecycle.poll(0, 1));
    try std.testing.expectEqual(session.SessionState.ready, (try lifecycle.status(handle)).state);

    var migration_provider = FakeMigrationProvider{};
    var migrations = try QuicMigrationPolicyRegistry.init(std.testing.allocator, &lifecycle, .{}, &migration_provider, .{ .validate_path = FakeMigrationProvider.validatePath });
    defer migrations.deinit();
    const first_endpoint = transport.Endpoint.from_ipv4(first_source);
    const second_endpoint = transport.Endpoint.from_ipv4(second_source);
    try migrations.register(handle, first_endpoint);
    try std.testing.expectEqual(@as(u64, 1), try migrations.migrate(handle, second_endpoint));
    try std.testing.expectEqual(@as(usize, 1), migration_provider.validations);
    try std.testing.expect(migration_provider.candidate.?.eql(second_endpoint));
    try std.testing.expect((try migrations.snapshot(handle)).pending_endpoint.?.eql(second_endpoint));
    try std.testing.expectEqual(@intFromEnum(core.CResult.ok), migration_provider.emit(.validated, 0));
    try std.testing.expectEqual(@as(usize, 1), try migrations.poll(1));
    const snapshot = try migrations.snapshot(handle);
    try std.testing.expect(snapshot.session == handle);
    try std.testing.expect(snapshot.current_endpoint.eql(second_endpoint));
    try std.testing.expect(snapshot.pending_endpoint == null);
    try std.testing.expectEqual(@as(u32, 1), snapshot.successful_migrations);
    try std.testing.expectEqual(session.SessionState.ready, (try lifecycle.status(handle)).state);
    var attributions: [2]QuicMigrationSecurityAttribution = undefined;
    try std.testing.expectEqual(@as(usize, 2), try migrations.listSecurityAttributions(attributions[0..]));
    try std.testing.expectEqual(QuicMigrationDecision.validation_started, attributions[0].decision);
    try std.testing.expectEqual(QuicMigrationDecision.migrated, attributions[1].decision);
    try std.testing.expectEqual(QuicMigrationReason.port_rebinding, attributions[1].reason);
}

test "QUIC migration policy rejects an address change and records its attribution" {
    const FakeConnectionProvider = struct {
        callback_context: ?*anyopaque = null,
        callback_fn: ?connections.QuicConnectionCallback = null,

        fn open(context: ?*anyopaque, _: u64, _: connections.QuicConnectionRole, callback_context: ?*anyopaque, callback_fn: connections.QuicConnectionCallback) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.callback_context = callback_context;
            self.callback_fn = callback_fn;
            return @intFromEnum(core.CResult.ok);
        }

        fn shutdown(_: ?*anyopaque, _: u64) callconv(.c) void {}

        fn connected(self: *@This(), connection_id: u64) c_int {
            const event = connections.QuicConnectionProviderEvent{ .connection_id = connection_id, .kind = @intFromEnum(connections.QuicConnectionEventKind.connected) };
            return self.callback_fn.?(self.callback_context, &event);
        }
    };
    const FakeMigrationProvider = struct {
        fn validatePath(_: ?*anyopaque, _: u64, _: u64, _: *const transport.Endpoint, _: ?*anyopaque, _: QuicPathValidationCallback) callconv(.c) c_int {
            return @intFromEnum(core.CResult.ok);
        }
    };

    var resources = try resource.ResourceRegistry.init(std.testing.allocator, 1);
    defer resources.deinit();
    var sessions = try session.SessionRegistry.init(std.testing.allocator, &resources, 1);
    defer sessions.deinit();
    var connection_provider = FakeConnectionProvider{};
    var lifecycle = try connections.QuicConnectionLifecycle.init(std.testing.allocator, &sessions, .{}, &connection_provider, .{ .open = FakeConnectionProvider.open, .shutdown = FakeConnectionProvider.shutdown });
    defer lifecycle.deinit();
    const handle = try lifecycle.connect(.{ .role = .client }, 0);
    try std.testing.expectEqual(@intFromEnum(core.CResult.ok), connection_provider.connected(try lifecycle.connectionId(handle)));
    _ = try lifecycle.poll(0, 1);
    var migrations = try QuicMigrationPolicyRegistry.init(std.testing.allocator, &lifecycle, .{}, null, .{ .validate_path = FakeMigrationProvider.validatePath });
    defer migrations.deinit();
    const current = transport.Endpoint.from_ipv4(.{ .octets = .{ 127, 0, 0, 1 }, .port = 4000 });
    const candidate = transport.Endpoint.from_ipv4(.{ .octets = .{ 127, 0, 0, 2 }, .port = 4000 });
    try migrations.register(handle, current);
    try std.testing.expectError(error.AddressChangeDisallowed, migrations.migrate(handle, candidate));
    var attributions: [1]QuicMigrationSecurityAttribution = undefined;
    try std.testing.expectEqual(@as(usize, 1), try migrations.listSecurityAttributions(attributions[0..]));
    try std.testing.expectEqual(QuicMigrationDecision.rejected_by_policy, attributions[0].decision);
    try std.testing.expectEqual(QuicMigrationReason.address_change_not_permitted, attributions[0].reason);
}

fn localAddress(socket: *transport.UdpSocket) !transport.Ipv4Address {
    var native = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
    var address_length = native.getOsSockLen();
    try std.posix.getsockname(socket.socket.handle, &native.any, &address_length);
    return transport.Ipv4Address.from_native(native);
}

fn receiveWithRetry(socket: *transport.UdpSocket, storage: []u8) !transport.ReceivedDatagram {
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        return socket.receive_from(storage) catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
    }
    return error.WouldBlock;
}
