const std = @import("std");
const core = @import("minna-san-core");

pub const max_tls_certificate_callback_pending: usize = 64;
pub const max_tls_server_name_bytes: usize = 255;
pub const max_tls_server_identities: usize = 64;
pub const max_tls_certificate_failure_events: usize = 64;

pub const TlsCertificateRequestId = u64;
pub const TlsCertificateChainId = u64;
pub const TlsPrivateKeyId = u64;

pub const TlsCertificateRequestKind = enum(u8) { server_identity, client_trust };
pub const TlsCertificateRejectionCause = enum(u8) { application_rejected, unrecognized_name, invalid_identity, not_yet_valid, stale_identity, identity_capacity_exceeded };
pub const TlsCertificateFailure = enum(u8) { rejected, expired, invalid_resolution };

pub const TlsServerIdentity = struct {
    certificate_chain_id: TlsCertificateChainId,
    private_key_id: TlsPrivateKeyId,
    not_before_ns: core.TimeNs,
    not_after_ns: core.TimeNs,
    generation: u64,
};

pub const TlsCertificateAcceptance = union(enum) {
    server_identity: TlsServerIdentity,
    client_trust: void,
};

pub const TlsCertificateResolution = union(enum) {
    accepted: TlsCertificateAcceptance,
    rejected: TlsCertificateRejectionCause,
    expired: void,
};

pub const TlsCertificateRequestInput = struct {
    kind: TlsCertificateRequestKind,
    server_name: []const u8 = &.{},
    peer_certificate_chain_id: ?TlsCertificateChainId = null,
    issued_at_ns: core.TimeNs,
    expires_at_ns: core.TimeNs,
};

pub const TlsCertificateRequest = struct {
    id: TlsCertificateRequestId,
    kind: TlsCertificateRequestKind,
    server_name: []const u8,
    peer_certificate_chain_id: ?TlsCertificateChainId,
    issued_at_ns: core.TimeNs,
    expires_at_ns: core.TimeNs,
};

pub const TlsCertificateRotation = struct {
    previous_generation: u64,
    current_generation: u64,
};

pub const TlsCertificateResolutionResult = struct {
    id: TlsCertificateRequestId,
    kind: TlsCertificateRequestKind,
    resolution: TlsCertificateResolution,
    rotation: ?TlsCertificateRotation = null,
};

pub const TlsCertificateFailureEvent = struct {
    sequence: u64,
    id: TlsCertificateRequestId,
    kind: TlsCertificateRequestKind,
    failure: TlsCertificateFailure,
};

pub const TlsCertificateCallbackBeginFn = *const fn (context: ?*anyopaque, request: TlsCertificateRequest) void;
pub const TlsCertificateCallbackPollFn = *const fn (context: ?*anyopaque, id: TlsCertificateRequestId) ?TlsCertificateResolution;

pub const ApplicationTlsCertificateCallback = struct {
    context: ?*anyopaque = null,
    begin: TlsCertificateCallbackBeginFn,
    poll: TlsCertificateCallbackPollFn,
};

pub const TlsCertificateCallbackConfig = struct {
    callback: ApplicationTlsCertificateCallback,
    maximum_pending: usize = max_tls_certificate_callback_pending,
    maximum_server_identities: usize = max_tls_server_identities,
    failure_event_capacity: usize = max_tls_certificate_failure_events,

    pub fn validate(self: TlsCertificateCallbackConfig) TlsCertificateCallbackError!void {
        if (self.maximum_pending == 0 or self.maximum_pending > max_tls_certificate_callback_pending or self.maximum_server_identities == 0 or self.maximum_server_identities > max_tls_server_identities or self.failure_event_capacity == 0 or self.failure_event_capacity > max_tls_certificate_failure_events) return error.InvalidConfiguration;
    }
};

pub const TlsCertificateCallbackError = std.mem.Allocator.Error || error{ InvalidConfiguration, InvalidRequest, RequestCapacityExceeded };

const PendingRequest = struct {
    id: TlsCertificateRequestId,
    kind: TlsCertificateRequestKind,
    server_name: [max_tls_server_name_bytes]u8 = undefined,
    server_name_len: usize,
    expires_at_ns: core.TimeNs,
};

const ActiveServerIdentity = struct {
    server_name: [max_tls_server_name_bytes]u8 = undefined,
    server_name_len: usize,
    identity: TlsServerIdentity,
};

pub const TlsCertificateCallbackRegistry = struct {
    allocator: std.mem.Allocator,
    config: TlsCertificateCallbackConfig,
    pending: std.ArrayListUnmanaged(PendingRequest) = .empty,
    active_server_identities: std.ArrayListUnmanaged(ActiveServerIdentity) = .empty,
    failure_events: [max_tls_certificate_failure_events]TlsCertificateFailureEvent = undefined,
    failure_event_count: usize = 0,
    next_request_id: TlsCertificateRequestId = 1,
    next_failure_sequence: u64 = 0,
    poll_cursor: usize = 0,

    pub fn init(allocator: std.mem.Allocator, config: TlsCertificateCallbackConfig) TlsCertificateCallbackError!TlsCertificateCallbackRegistry {
        try config.validate();
        var pending: std.ArrayListUnmanaged(PendingRequest) = .empty;
        errdefer pending.deinit(allocator);
        try pending.ensureTotalCapacityPrecise(allocator, config.maximum_pending);
        var active_server_identities: std.ArrayListUnmanaged(ActiveServerIdentity) = .empty;
        errdefer active_server_identities.deinit(allocator);
        try active_server_identities.ensureTotalCapacityPrecise(allocator, config.maximum_server_identities);
        return .{ .allocator = allocator, .config = config, .pending = pending, .active_server_identities = active_server_identities };
    }

    pub fn deinit(self: *TlsCertificateCallbackRegistry) void {
        self.pending.deinit(self.allocator);
        self.active_server_identities.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn begin(self: *TlsCertificateCallbackRegistry, input: TlsCertificateRequestInput) TlsCertificateCallbackError!TlsCertificateRequestId {
        try self.validateInput(input);
        if (self.pending.items.len == self.config.maximum_pending) return error.RequestCapacityExceeded;
        const id = self.next_request_id;
        self.next_request_id +%= 1;
        if (self.next_request_id == 0) self.next_request_id = 1;
        var pending = PendingRequest{ .id = id, .kind = input.kind, .server_name_len = input.server_name.len, .expires_at_ns = input.expires_at_ns };
        @memcpy(pending.server_name[0..input.server_name.len], input.server_name);
        self.pending.appendAssumeCapacity(pending);
        self.config.callback.begin(self.config.callback.context, .{
            .id = id,
            .kind = input.kind,
            .server_name = input.server_name,
            .peer_certificate_chain_id = input.peer_certificate_chain_id,
            .issued_at_ns = input.issued_at_ns,
            .expires_at_ns = input.expires_at_ns,
        });
        return id;
    }

    pub fn poll(self: *TlsCertificateCallbackRegistry, now_ns: core.TimeNs) ?TlsCertificateResolutionResult {
        if (self.expiredIndex(now_ns)) |index| return self.resolve(index, .expired, null);
        if (self.pending.items.len == 0) return null;
        const index = self.poll_cursor % self.pending.items.len;
        self.poll_cursor = (index + 1) % self.pending.items.len;
        const pending = self.pending.items[index];
        const resolution = self.config.callback.poll(self.config.callback.context, pending.id) orelse return null;
        return self.resolveCallback(index, now_ns, resolution);
    }

    pub fn pollFailureEvent(self: *TlsCertificateCallbackRegistry) ?TlsCertificateFailureEvent {
        if (self.failure_event_count == 0) return null;
        const result = self.failure_events[0];
        for (self.failure_events[1..self.failure_event_count], 0..) |event, index| self.failure_events[index] = event;
        self.failure_event_count -= 1;
        return result;
    }

    pub fn pendingCount(self: *const TlsCertificateCallbackRegistry) usize {
        return self.pending.items.len;
    }

    fn validateInput(_: *const TlsCertificateCallbackRegistry, input: TlsCertificateRequestInput) TlsCertificateCallbackError!void {
        if (input.expires_at_ns <= input.issued_at_ns or input.server_name.len > max_tls_server_name_bytes) return error.InvalidRequest;
        switch (input.kind) {
            .server_identity => if (input.peer_certificate_chain_id != null) return error.InvalidRequest,
            .client_trust => if (input.peer_certificate_chain_id == null or input.peer_certificate_chain_id.? == 0) return error.InvalidRequest,
        }
    }

    fn expiredIndex(self: *const TlsCertificateCallbackRegistry, now_ns: core.TimeNs) ?usize {
        for (self.pending.items, 0..) |pending, index| if (now_ns >= pending.expires_at_ns) return index;
        return null;
    }

    fn resolveCallback(self: *TlsCertificateCallbackRegistry, index: usize, now_ns: core.TimeNs, resolution: TlsCertificateResolution) TlsCertificateResolutionResult {
        const pending = self.pending.items[index];
        switch (resolution) {
            .expired => return self.resolve(index, .expired, null),
            .rejected => |cause| return self.resolve(index, .{ .rejected = cause }, null),
            .accepted => |acceptance| switch (pending.kind) {
                .client_trust => switch (acceptance) {
                    .client_trust => return self.resolve(index, .{ .accepted = .client_trust }, null),
                    .server_identity => return self.resolveInvalid(index),
                },
                .server_identity => switch (acceptance) {
                    .client_trust => return self.resolveInvalid(index),
                    .server_identity => |identity| return self.resolveServerIdentity(index, now_ns, identity),
                },
            },
        }
    }

    fn resolveServerIdentity(self: *TlsCertificateCallbackRegistry, index: usize, now_ns: core.TimeNs, identity: TlsServerIdentity) TlsCertificateResolutionResult {
        if (identity.certificate_chain_id == 0 or identity.private_key_id == 0 or identity.generation == 0 or identity.not_after_ns <= identity.not_before_ns) return self.resolveInvalid(index);
        if (now_ns < identity.not_before_ns) return self.resolve(index, .{ .rejected = .not_yet_valid }, null);
        if (now_ns >= identity.not_after_ns) return self.resolve(index, .expired, null);
        const pending = self.pending.items[index];
        if (self.activeServerIdentityIndex(pending.server_name[0..pending.server_name_len])) |active_index| {
            const active = &self.active_server_identities.items[active_index];
            if (identity.generation < active.identity.generation) return self.resolve(index, .{ .rejected = .stale_identity }, null);
            if (identity.generation == active.identity.generation) {
                if (!std.meta.eql(identity, active.identity)) return self.resolve(index, .{ .rejected = .stale_identity }, null);
                return self.resolve(index, .{ .accepted = .{ .server_identity = identity } }, null);
            }
            const rotation = TlsCertificateRotation{ .previous_generation = active.identity.generation, .current_generation = identity.generation };
            active.identity = identity;
            return self.resolve(index, .{ .accepted = .{ .server_identity = identity } }, rotation);
        }
        if (self.active_server_identities.items.len == self.config.maximum_server_identities) return self.resolve(index, .{ .rejected = .identity_capacity_exceeded }, null);
        var active = ActiveServerIdentity{ .server_name_len = pending.server_name_len, .identity = identity };
        @memcpy(active.server_name[0..pending.server_name_len], pending.server_name[0..pending.server_name_len]);
        self.active_server_identities.appendAssumeCapacity(active);
        return self.resolve(index, .{ .accepted = .{ .server_identity = identity } }, null);
    }

    fn resolveInvalid(self: *TlsCertificateCallbackRegistry, index: usize) TlsCertificateResolutionResult {
        const pending = self.pending.swapRemove(index);
        if (self.pending.items.len == 0) self.poll_cursor = 0 else self.poll_cursor %= self.pending.items.len;
        self.recordFailure(pending.id, pending.kind, .invalid_resolution);
        return .{ .id = pending.id, .kind = pending.kind, .resolution = .{ .rejected = .invalid_identity } };
    }

    fn resolve(self: *TlsCertificateCallbackRegistry, index: usize, resolution: TlsCertificateResolution, rotation: ?TlsCertificateRotation) TlsCertificateResolutionResult {
        const pending = self.pending.swapRemove(index);
        if (self.pending.items.len == 0) self.poll_cursor = 0 else self.poll_cursor %= self.pending.items.len;
        const result = TlsCertificateResolutionResult{ .id = pending.id, .kind = pending.kind, .resolution = resolution, .rotation = rotation };
        switch (resolution) {
            .accepted => {},
            .rejected => self.recordFailure(pending.id, pending.kind, .rejected),
            .expired => self.recordFailure(pending.id, pending.kind, .expired),
        }
        return result;
    }

    fn activeServerIdentityIndex(self: *const TlsCertificateCallbackRegistry, server_name: []const u8) ?usize {
        for (self.active_server_identities.items, 0..) |active, index| if (std.mem.eql(u8, active.server_name[0..active.server_name_len], server_name)) return index;
        return null;
    }

    fn recordFailure(self: *TlsCertificateCallbackRegistry, id: TlsCertificateRequestId, kind: TlsCertificateRequestKind, failure: TlsCertificateFailure) void {
        if (self.failure_event_count == self.config.failure_event_capacity) return;
        self.failure_events[self.failure_event_count] = .{ .sequence = self.next_failure_sequence, .id = id, .kind = kind, .failure = failure };
        self.failure_event_count += 1;
        self.next_failure_sequence +%= 1;
    }
};

test "TLS certificate callbacks resolve accepted rejected expired client-trust and rotated identities" {
    const Fixture = struct {
        saw_sni: bool = false,

        fn begin(context: ?*anyopaque, request: TlsCertificateRequest) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (request.id == 1) self.saw_sni = std.mem.eql(u8, request.server_name, "api.example.test");
        }

        fn poll(_: ?*anyopaque, id: TlsCertificateRequestId) ?TlsCertificateResolution {
            return switch (id) {
                1 => .{ .accepted = .{ .server_identity = .{ .certificate_chain_id = 7, .private_key_id = 11, .not_before_ns = 1, .not_after_ns = 20, .generation = 1 } } },
                2 => .{ .rejected = .unrecognized_name },
                3 => .expired,
                4 => .{ .accepted = .client_trust },
                5 => .{ .accepted = .{ .server_identity = .{ .certificate_chain_id = 13, .private_key_id = 17, .not_before_ns = 1, .not_after_ns = 30, .generation = 2 } } },
                else => null,
            };
        }
    };
    var fixture = Fixture{};
    var registry = try TlsCertificateCallbackRegistry.init(std.testing.allocator, .{ .callback = .{ .context = &fixture, .begin = Fixture.begin, .poll = Fixture.poll }, .maximum_pending = 5, .maximum_server_identities = 1, .failure_event_capacity = 3 });
    defer registry.deinit();
    const accepted_id = try registry.begin(.{ .kind = .server_identity, .server_name = "api.example.test", .issued_at_ns = 1, .expires_at_ns = 15 });
    const rejected_id = try registry.begin(.{ .kind = .server_identity, .server_name = "other.example.test", .issued_at_ns = 1, .expires_at_ns = 15 });
    const expired_id = try registry.begin(.{ .kind = .server_identity, .server_name = "expired.example.test", .issued_at_ns = 1, .expires_at_ns = 15 });
    const trusted_id = try registry.begin(.{ .kind = .client_trust, .server_name = "api.example.test", .peer_certificate_chain_id = 7, .issued_at_ns = 1, .expires_at_ns = 15 });
    try std.testing.expect(fixture.saw_sni);
    const accepted = registry.poll(10).?;
    try std.testing.expectEqual(accepted_id, accepted.id);
    try std.testing.expect(accepted.resolution == .accepted);
    try std.testing.expectEqual(@as(u64, 1), accepted.resolution.accepted.server_identity.generation);
    const rejected = registry.poll(10).?;
    try std.testing.expectEqual(rejected_id, rejected.id);
    try std.testing.expectEqual(TlsCertificateRejectionCause.unrecognized_name, rejected.resolution.rejected);
    const expired = registry.poll(10).?;
    try std.testing.expectEqual(expired_id, expired.id);
    try std.testing.expect(expired.resolution == .expired);
    const trusted = registry.poll(10).?;
    try std.testing.expectEqual(trusted_id, trusted.id);
    try std.testing.expect(trusted.resolution.accepted == .client_trust);
    const rotated_id = try registry.begin(.{ .kind = .server_identity, .server_name = "api.example.test", .issued_at_ns = 10, .expires_at_ns = 25 });
    const rotated = registry.poll(10).?;
    try std.testing.expectEqual(rotated_id, rotated.id);
    try std.testing.expectEqual(TlsCertificateRotation{ .previous_generation = 1, .current_generation = 2 }, rotated.rotation.?);
    try std.testing.expectEqual(TlsCertificateFailureEvent{ .sequence = 0, .id = rejected_id, .kind = .server_identity, .failure = .rejected }, registry.pollFailureEvent().?);
    try std.testing.expectEqual(TlsCertificateFailureEvent{ .sequence = 1, .id = expired_id, .kind = .server_identity, .failure = .expired }, registry.pollFailureEvent().?);
    try std.testing.expect(!@hasField(TlsCertificateFailureEvent, "server_name"));
    try std.testing.expect(!@hasField(TlsCertificateFailureEvent, "private_key_id"));
}

test "TLS certificate callbacks reject malformed requests and invalid callback resolutions" {
    const Fixture = struct {
        fn begin(_: ?*anyopaque, _: TlsCertificateRequest) void {}
        fn poll(_: ?*anyopaque, _: TlsCertificateRequestId) ?TlsCertificateResolution {
            return .{ .accepted = .client_trust };
        }
    };
    const callback = ApplicationTlsCertificateCallback{ .begin = Fixture.begin, .poll = Fixture.poll };
    try std.testing.expectError(error.InvalidConfiguration, TlsCertificateCallbackRegistry.init(std.testing.allocator, .{ .callback = callback, .maximum_pending = 0 }));
    var registry = try TlsCertificateCallbackRegistry.init(std.testing.allocator, .{ .callback = callback, .maximum_pending = 1, .maximum_server_identities = 1, .failure_event_capacity = 1 });
    defer registry.deinit();
    try std.testing.expectError(error.InvalidRequest, registry.begin(.{ .kind = .client_trust, .server_name = "api.example.test", .issued_at_ns = 0, .expires_at_ns = 1 }));
    try std.testing.expectError(error.InvalidRequest, registry.begin(.{ .kind = .server_identity, .server_name = "api.example.test", .peer_certificate_chain_id = 1, .issued_at_ns = 0, .expires_at_ns = 1 }));
    const id = try registry.begin(.{ .kind = .server_identity, .server_name = "api.example.test", .issued_at_ns = 0, .expires_at_ns = 2 });
    const invalid = registry.poll(1).?;
    try std.testing.expectEqual(id, invalid.id);
    try std.testing.expectEqual(TlsCertificateRejectionCause.invalid_identity, invalid.resolution.rejected);
    try std.testing.expectEqual(TlsCertificateFailureEvent{ .sequence = 0, .id = id, .kind = .server_identity, .failure = .invalid_resolution }, registry.pollFailureEvent().?);
}
