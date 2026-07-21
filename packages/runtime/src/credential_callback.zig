const std = @import("std");
const core = @import("minna-san-core");

pub const max_credential_callback_pending: usize = 4_096;
pub const max_credential_callback_bytes: usize = 16 * 1024;
pub const max_credential_callback_route_bytes: usize = 128;
pub const CredentialChallengeId = u64;
pub const CredentialChallengeTarget = union(enum) {
    peer: u64,
    service: void,
};
pub const CredentialRejectionCause = enum(u8) { invalid_credentials, unauthorized, revoked, rate_limited, timed_out };
pub const CredentialDecision = union(enum) {
    accepted: void,
    rejected: CredentialRejectionCause,
};
pub const CredentialChallengeInput = struct {
    target: CredentialChallengeTarget,
    service_route: []const u8 = "",
    credentials: []const u8,
    issued_at_ns: core.TimeNs,
    expires_at_ns: core.TimeNs,
};
pub const CredentialChallenge = struct {
    id: CredentialChallengeId,
    target: CredentialChallengeTarget,
    service_route: []const u8,
    credentials: []const u8,
    issued_at_ns: core.TimeNs,
    expires_at_ns: core.TimeNs,
};
pub const CredentialPollResult = struct {
    id: CredentialChallengeId,
    target: CredentialChallengeTarget,
    decision: CredentialDecision,
};
pub const CredentialCallbackBeginFn = *const fn (context: ?*anyopaque, challenge: CredentialChallenge) void;
pub const CredentialCallbackPollFn = *const fn (context: ?*anyopaque, id: CredentialChallengeId) ?CredentialDecision;
pub const ApplicationCredentialCallback = struct {
    context: ?*anyopaque = null,
    begin: CredentialCallbackBeginFn,
    poll: CredentialCallbackPollFn,
};
pub const CredentialCallbackConfig = struct {
    callback: ApplicationCredentialCallback,
    maximum_pending: usize = 64,
    maximum_credential_bytes: usize = 1_024,

    pub fn validate(self: CredentialCallbackConfig) CredentialCallbackError!void {
        if (self.maximum_pending == 0 or self.maximum_pending > max_credential_callback_pending or self.maximum_credential_bytes == 0 or self.maximum_credential_bytes > max_credential_callback_bytes) return error.InvalidConfiguration;
    }
};
pub const CredentialCallbackError = std.mem.Allocator.Error || error{ InvalidConfiguration, InvalidChallenge, ChallengeCapacityExceeded };

const PendingChallenge = struct {
    id: CredentialChallengeId,
    target: CredentialChallengeTarget,
    expires_at_ns: core.TimeNs,
};

pub const CredentialCallbackRegistry = struct {
    allocator: std.mem.Allocator,
    config: CredentialCallbackConfig,
    pending: std.ArrayListUnmanaged(PendingChallenge) = .empty,
    next_id: CredentialChallengeId = 1,
    poll_cursor: usize = 0,

    pub fn init(allocator: std.mem.Allocator, config: CredentialCallbackConfig) CredentialCallbackError!CredentialCallbackRegistry {
        try config.validate();
        var pending: std.ArrayListUnmanaged(PendingChallenge) = .empty;
        errdefer pending.deinit(allocator);
        try pending.ensureTotalCapacityPrecise(allocator, config.maximum_pending);
        return .{ .allocator = allocator, .config = config, .pending = pending };
    }

    pub fn deinit(self: *CredentialCallbackRegistry) void {
        self.pending.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn begin(self: *CredentialCallbackRegistry, input: CredentialChallengeInput) CredentialCallbackError!CredentialChallengeId {
        try self.validateInput(input);
        if (self.pending.items.len == self.config.maximum_pending) return error.ChallengeCapacityExceeded;
        const id = self.next_id;
        self.next_id +%= 1;
        if (self.next_id == 0) self.next_id = 1;
        self.pending.appendAssumeCapacity(.{ .id = id, .target = input.target, .expires_at_ns = input.expires_at_ns });
        self.config.callback.begin(self.config.callback.context, .{
            .id = id,
            .target = input.target,
            .service_route = input.service_route,
            .credentials = input.credentials,
            .issued_at_ns = input.issued_at_ns,
            .expires_at_ns = input.expires_at_ns,
        });
        return id;
    }

    pub fn poll(self: *CredentialCallbackRegistry, now_ns: core.TimeNs) ?CredentialPollResult {
        if (self.expiredIndex(now_ns)) |index| return self.resolve(index, .{ .rejected = .timed_out });
        if (self.pending.items.len == 0) return null;
        const index = self.poll_cursor % self.pending.items.len;
        self.poll_cursor = (index + 1) % self.pending.items.len;
        const pending = self.pending.items[index];
        const decision = self.config.callback.poll(self.config.callback.context, pending.id) orelse return null;
        return self.resolve(index, decision);
    }

    pub fn nextDeadline(self: *const CredentialCallbackRegistry) ?core.TimeNs {
        var deadline: ?core.TimeNs = null;
        for (self.pending.items) |pending| deadline = if (deadline) |current| @min(current, pending.expires_at_ns) else pending.expires_at_ns;
        return deadline;
    }

    pub fn pendingCount(self: *const CredentialCallbackRegistry) usize {
        return self.pending.items.len;
    }

    fn validateInput(self: *const CredentialCallbackRegistry, input: CredentialChallengeInput) CredentialCallbackError!void {
        if (input.expires_at_ns <= input.issued_at_ns or input.credentials.len > self.config.maximum_credential_bytes) return error.InvalidChallenge;
        switch (input.target) {
            .peer => |peer| if (peer == 0) return error.InvalidChallenge,
            .service => if (input.service_route.len == 0 or input.service_route.len > max_credential_callback_route_bytes or input.service_route[0] != '/') return error.InvalidChallenge,
        }
    }

    fn expiredIndex(self: *const CredentialCallbackRegistry, now_ns: core.TimeNs) ?usize {
        for (self.pending.items, 0..) |pending, index| if (now_ns >= pending.expires_at_ns) return index;
        return null;
    }

    fn resolve(self: *CredentialCallbackRegistry, index: usize, decision: CredentialDecision) CredentialPollResult {
        const pending = self.pending.swapRemove(index);
        if (self.pending.items.len == 0) self.poll_cursor = 0 else self.poll_cursor %= self.pending.items.len;
        return .{ .id = pending.id, .target = pending.target, .decision = decision };
    }
};

test "application credential callbacks accept reject and time out through bounded polls" {
    const Fixture = struct {
        began: usize = 0,
        pending_id: CredentialChallengeId = 0,

        fn begin(context: ?*anyopaque, challenge: CredentialChallenge) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.began += 1;
            if (challenge.target == .service) std.debug.assert(std.mem.eql(u8, challenge.service_route, "/service"));
            self.pending_id = challenge.id;
        }

        fn poll(context: ?*anyopaque, id: CredentialChallengeId) ?CredentialDecision {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (id == 1) return .{ .accepted = {} };
            if (id == 2) return .{ .rejected = .invalid_credentials };
            std.debug.assert(id == self.pending_id);
            return null;
        }
    };
    var fixture = Fixture{};
    var registry = try CredentialCallbackRegistry.init(std.testing.allocator, .{ .callback = .{ .context = &fixture, .begin = Fixture.begin, .poll = Fixture.poll }, .maximum_pending = 3, .maximum_credential_bytes = 16 });
    defer registry.deinit();
    const accepted = try registry.begin(.{ .target = .{ .peer = 7 }, .credentials = "peer", .issued_at_ns = 1, .expires_at_ns = 8 });
    const rejected = try registry.begin(.{ .target = .service, .service_route = "/service", .credentials = "service", .issued_at_ns = 1, .expires_at_ns = 8 });
    const pending = try registry.begin(.{ .target = .{ .peer = 9 }, .credentials = "later", .issued_at_ns = 1, .expires_at_ns = 8 });
    try std.testing.expectEqual(@as(CredentialChallengeId, 1), accepted);
    try std.testing.expectEqual(@as(CredentialChallengeId, 2), rejected);
    try std.testing.expectEqual(@as(usize, 3), fixture.began);
    const first = registry.poll(1).?;
    try std.testing.expectEqual(accepted, first.id);
    try std.testing.expect(first.decision == .accepted);
    const second = registry.poll(1).?;
    try std.testing.expectEqual(rejected, second.id);
    try std.testing.expectEqual(CredentialRejectionCause.invalid_credentials, second.decision.rejected);
    try std.testing.expect(registry.poll(1) == null);
    const timed_out = registry.poll(8).?;
    try std.testing.expectEqual(pending, timed_out.id);
    try std.testing.expectEqual(CredentialRejectionCause.timed_out, timed_out.decision.rejected);
    try std.testing.expectEqual(@as(usize, 0), registry.pendingCount());
}

test "application credential callbacks bound challenge configuration and inputs" {
    const no_op = struct {
        fn begin(_: ?*anyopaque, _: CredentialChallenge) void {}
        fn poll(_: ?*anyopaque, _: CredentialChallengeId) ?CredentialDecision {
            return null;
        }
    };
    const callback = ApplicationCredentialCallback{ .begin = no_op.begin, .poll = no_op.poll };
    try std.testing.expectError(error.InvalidConfiguration, CredentialCallbackRegistry.init(std.testing.allocator, .{ .callback = callback, .maximum_pending = 0 }));
    var registry = try CredentialCallbackRegistry.init(std.testing.allocator, .{ .callback = callback, .maximum_pending = 1, .maximum_credential_bytes = 2 });
    defer registry.deinit();
    try std.testing.expectError(error.InvalidChallenge, registry.begin(.{ .target = .{ .peer = 0 }, .credentials = "", .issued_at_ns = 0, .expires_at_ns = 1 }));
    try std.testing.expectError(error.InvalidChallenge, registry.begin(.{ .target = .service, .credentials = "ok", .issued_at_ns = 0, .expires_at_ns = 1 }));
    _ = try registry.begin(.{ .target = .{ .peer = 1 }, .credentials = "ok", .issued_at_ns = 0, .expires_at_ns = 1 });
    try std.testing.expectError(error.ChallengeCapacityExceeded, registry.begin(.{ .target = .{ .peer = 2 }, .credentials = "ok", .issued_at_ns = 0, .expires_at_ns = 1 }));
}
