pub const RecoveryTarget = union(enum) { host: u64, shard: u64 };
pub const RecoveryState = enum { idle, reconnecting, resubscribing, resyncing, recovered, failed };
pub const RecoveryTerminalReason = enum { reconnect_failed, resubscribe_failed, resync_failed };
pub const RecoveryEvent = union(enum) {
    reconnect: struct { target: RecoveryTarget, attempt: u8 },
    resubscribe: RecoveryTarget,
    resync: RecoveryTarget,
    recovered: RecoveryTarget,
    terminal_failure: struct { target: RecoveryTarget, reason: RecoveryTerminalReason },
};
pub const AuthoritativeRecoveryError = error{ InvalidConfiguration, InvalidTarget, InvalidState };
pub const AuthoritativeRecoveryConfig = struct { maximum_reconnect_attempts: u8 };

pub const AuthoritativeSessionRecovery = struct {
    config: AuthoritativeRecoveryConfig,
    state: RecoveryState = .idle,
    target: ?RecoveryTarget = null,
    attempts: u8 = 0,

    pub fn init(config: AuthoritativeRecoveryConfig) AuthoritativeRecoveryError!AuthoritativeSessionRecovery {
        if (config.maximum_reconnect_attempts == 0) return error.InvalidConfiguration;
        return .{ .config = config };
    }
    pub fn current_state(self: AuthoritativeSessionRecovery) RecoveryState {
        return self.state;
    }
    pub fn begin(self: *AuthoritativeSessionRecovery, recovery_target: RecoveryTarget) AuthoritativeRecoveryError!RecoveryEvent {
        if (self.state != .idle and self.state != .recovered and self.state != .failed) return error.InvalidState;
        if (!valid_target(recovery_target)) return error.InvalidTarget;
        self.target = recovery_target;
        self.attempts = 1;
        self.state = .reconnecting;
        return .{ .reconnect = .{ .target = recovery_target, .attempt = self.attempts } };
    }
    pub fn reconnect_result(self: *AuthoritativeSessionRecovery, success: bool) AuthoritativeRecoveryError!RecoveryEvent {
        const recovery_target = try self.require_state(.reconnecting);
        if (!success) return self.retry_or_fail(recovery_target, .reconnect_failed);
        self.state = .resubscribing;
        return .{ .resubscribe = recovery_target };
    }
    pub fn resubscribe_result(self: *AuthoritativeSessionRecovery, success: bool) AuthoritativeRecoveryError!RecoveryEvent {
        const recovery_target = try self.require_state(.resubscribing);
        if (!success) return self.retry_or_fail(recovery_target, .resubscribe_failed);
        self.state = .resyncing;
        return .{ .resync = recovery_target };
    }
    pub fn resync_result(self: *AuthoritativeSessionRecovery, success: bool) AuthoritativeRecoveryError!RecoveryEvent {
        const recovery_target = try self.require_state(.resyncing);
        if (!success) return self.retry_or_fail(recovery_target, .resync_failed);
        self.state = .recovered;
        return .{ .recovered = recovery_target };
    }
    fn retry_or_fail(self: *AuthoritativeSessionRecovery, recovery_target: RecoveryTarget, reason: RecoveryTerminalReason) RecoveryEvent {
        if (self.attempts == self.config.maximum_reconnect_attempts) {
            self.state = .failed;
            return .{ .terminal_failure = .{ .target = recovery_target, .reason = reason } };
        }
        self.attempts += 1;
        self.state = .reconnecting;
        return .{ .reconnect = .{ .target = recovery_target, .attempt = self.attempts } };
    }
    fn require_state(self: AuthoritativeSessionRecovery, expected: RecoveryState) AuthoritativeRecoveryError!RecoveryTarget {
        if (self.state != expected) return error.InvalidState;
        return self.target.?;
    }
};

fn valid_target(recovery_target: RecoveryTarget) bool {
    return switch (recovery_target) {
        .host => |id| id != 0,
        .shard => |id| id != 0,
    };
}

test "authoritative recovery reconnects resubscribes resyncs and recovers" {
    var recovery = try AuthoritativeSessionRecovery.init(.{ .maximum_reconnect_attempts = 2 });
    const target = RecoveryTarget{ .host = 7 };
    try @import("std").testing.expectEqual(RecoveryEvent{ .reconnect = .{ .target = target, .attempt = 1 } }, try recovery.begin(target));
    try @import("std").testing.expectEqual(RecoveryEvent{ .resubscribe = target }, try recovery.reconnect_result(true));
    try @import("std").testing.expectEqual(RecoveryEvent{ .resync = target }, try recovery.resubscribe_result(true));
    try @import("std").testing.expectEqual(RecoveryEvent{ .recovered = target }, try recovery.resync_result(true));
    try @import("std").testing.expectEqual(RecoveryState.recovered, recovery.current_state());
}

test "authoritative recovery bounds retry and emits terminal failures" {
    var recovery = try AuthoritativeSessionRecovery.init(.{ .maximum_reconnect_attempts = 2 });
    const target = RecoveryTarget{ .shard = 3 };
    _ = try recovery.begin(target);
    try @import("std").testing.expectEqual(RecoveryEvent{ .reconnect = .{ .target = target, .attempt = 2 } }, try recovery.reconnect_result(false));
    try @import("std").testing.expectEqual(RecoveryEvent{ .terminal_failure = .{ .target = target, .reason = .reconnect_failed } }, try recovery.reconnect_result(false));
    try @import("std").testing.expectEqual(RecoveryState.failed, recovery.current_state());
    try @import("std").testing.expectError(error.InvalidState, recovery.resync_result(true));
    try @import("std").testing.expectError(error.InvalidTarget, recovery.begin(.{ .host = 0 }));
    try @import("std").testing.expectError(error.InvalidConfiguration, AuthoritativeSessionRecovery.init(.{ .maximum_reconnect_attempts = 0 }));
}
