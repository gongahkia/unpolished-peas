const std = @import("std");
const core = @import("minna-san-core");
const baseline = @import("snapshot_baseline.zig");
const publisher = @import("snapshot_publisher.zig");

pub const StateRecoveryRequestId = u64;
pub const StateRecoveryReason = enum { missing_baseline, invalid_baseline, expired_baseline, incompatible_baseline };
pub const StateDeltaBaseline = struct {
    baseline: ?baseline.StateSnapshotBaseline,
    expires_at_ns: core.TimeNs,
};
pub const StateFullStateRecoveryRequest = struct {
    id: StateRecoveryRequestId,
    reason: StateRecoveryReason,
    baseline_sequence: ?publisher.StateSnapshotSequence,
};
pub const StateFullStateRecoveryError = error{ InvalidConfiguration, RequestCapacityExceeded, RequestIdExhausted, UnknownRequest };
pub const StateFullStateRecoveryConfig = struct {
    expected_schema_version: u32,
    maximum_baseline_bytes: usize,
    maximum_requests: usize,
};
pub const StateFullStateRecovery = struct {
    config: StateFullStateRecoveryConfig,
    requests: [64]StateFullStateRecoveryRequest = undefined,
    request_count: usize = 0,
    next_id: StateRecoveryRequestId = 0,

    pub fn init(config: StateFullStateRecoveryConfig) StateFullStateRecoveryError!StateFullStateRecovery {
        if (config.expected_schema_version == 0 or config.maximum_baseline_bytes == 0 or config.maximum_requests == 0 or config.maximum_requests > 64) return error.InvalidConfiguration;
        return .{ .config = config };
    }
    pub fn request(self: *StateFullStateRecovery, value: StateDeltaBaseline, now_ns: core.TimeNs) StateFullStateRecoveryError!StateFullStateRecoveryRequest {
        if (self.request_count == self.config.maximum_requests) return error.RequestCapacityExceeded;
        if (self.next_id == std.math.maxInt(StateRecoveryRequestId)) return error.RequestIdExhausted;
        const reason = self.classify(value, now_ns);
        const output = StateFullStateRecoveryRequest{ .id = self.next_id, .reason = reason, .baseline_sequence = if (value.baseline) |item| item.sequence else null };
        self.next_id += 1;
        self.requests[self.request_count] = output;
        self.request_count += 1;
        return output;
    }
    pub fn complete(self: *StateFullStateRecovery, id: StateRecoveryRequestId) StateFullStateRecoveryError!void {
        for (self.requests[0..self.request_count], 0..) |value, index| {
            if (value.id != id) continue;
            for (self.requests[index + 1 .. self.request_count], index..) |next, destination| self.requests[destination] = next;
            self.request_count -= 1;
            return;
        }
        return error.UnknownRequest;
    }
    pub fn pending(self: *const StateFullStateRecovery) []const StateFullStateRecoveryRequest {
        return self.requests[0..self.request_count];
    }
    fn classify(self: StateFullStateRecovery, value: StateDeltaBaseline, now_ns: core.TimeNs) StateRecoveryReason {
        const item = value.baseline orelse return .missing_baseline;
        if (!item.acknowledged or item.state.bytes.len == 0 or item.state.bytes.len > self.config.maximum_baseline_bytes) return .invalid_baseline;
        if (value.expires_at_ns < now_ns) return .expired_baseline;
        if (item.schema_version != self.config.expected_schema_version) return .incompatible_baseline;
        return .invalid_baseline;
    }
};

test "full-state recovery classifies missing invalid expired and incompatible baselines without mutating them" {
    var recovery = try StateFullStateRecovery.init(.{ .expected_schema_version = 2, .maximum_baseline_bytes = 2, .maximum_requests = 4 });
    const missing = try recovery.request(.{ .baseline = null, .expires_at_ns = 1 }, 1);
    const invalid = try recovery.request(.{ .baseline = .{ .sequence = 1, .schema_version = 2, .state = .init(""), .acknowledged = false }, .expires_at_ns = 1 }, 1);
    const expired = try recovery.request(.{ .baseline = .{ .sequence = 2, .schema_version = 2, .state = .init("ok"), .acknowledged = true }, .expires_at_ns = 0 }, 1);
    const incompatible = try recovery.request(.{ .baseline = .{ .sequence = 3, .schema_version = 1, .state = .init("ok"), .acknowledged = true }, .expires_at_ns = 1 }, 1);
    try std.testing.expectEqual(StateRecoveryReason.missing_baseline, missing.reason);
    try std.testing.expectEqual(StateRecoveryReason.invalid_baseline, invalid.reason);
    try std.testing.expectEqual(StateRecoveryReason.expired_baseline, expired.reason);
    try std.testing.expectEqual(StateRecoveryReason.incompatible_baseline, incompatible.reason);
    try std.testing.expectEqual(@as(usize, 4), recovery.pending().len);
    try recovery.complete(expired.id);
    try std.testing.expectEqual(@as(usize, 3), recovery.pending().len);
}

test "full-state recovery bounds requests and rejects invalid completion" {
    try std.testing.expectError(error.InvalidConfiguration, StateFullStateRecovery.init(.{ .expected_schema_version = 0, .maximum_baseline_bytes = 1, .maximum_requests = 1 }));
    var recovery = try StateFullStateRecovery.init(.{ .expected_schema_version = 1, .maximum_baseline_bytes = 1, .maximum_requests = 1 });
    _ = try recovery.request(.{ .baseline = null, .expires_at_ns = 0 }, 0);
    try std.testing.expectError(error.RequestCapacityExceeded, recovery.request(.{ .baseline = null, .expires_at_ns = 0 }, 0));
    try std.testing.expectError(error.UnknownRequest, recovery.complete(2));
}
