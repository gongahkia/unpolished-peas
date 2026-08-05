const core = @import("minna-san-core");
const allocation = @import("turn_allocation.zig");

pub const TurnAllocationLifecycleError = error{ InvalidConfiguration, NoAllocation, CredentialExpired, RefreshNotDue, AllocationExpired, FailureLimitReached };
pub const TurnAllocationFailure = enum { transport, authentication, server_rejected };
pub const TurnAllocationEvent = union(enum) { refresh_due: allocation.TurnAllocation, deallocated, recoverable_failure: TurnAllocationFailure };
pub const TurnAllocationLifecycleConfig = struct { credential_expires_at_ns: core.TimeNs, refresh_margin_ns: core.TimeNs, maximum_failures: usize };

pub const TurnAllocationLifecycle = struct {
    config: TurnAllocationLifecycleConfig,
    allocation: ?allocation.TurnAllocation = null,
    failures: usize = 0,

    pub fn init(config: TurnAllocationLifecycleConfig) TurnAllocationLifecycleError!TurnAllocationLifecycle {
        if (config.credential_expires_at_ns == 0 or config.refresh_margin_ns == 0 or config.maximum_failures == 0) return error.InvalidConfiguration;
        return .{ .config = config };
    }
    pub fn activate(self: *TurnAllocationLifecycle, value: allocation.TurnAllocation, now_ns: core.TimeNs) TurnAllocationLifecycleError!void {
        if (value.expires_at_ns <= now_ns) return error.AllocationExpired;
        self.allocation = value;
        self.failures = 0;
    }
    pub fn poll(self: TurnAllocationLifecycle, now_ns: core.TimeNs) TurnAllocationLifecycleError!?TurnAllocationEvent {
        if (now_ns >= self.config.credential_expires_at_ns) return error.CredentialExpired;
        const value = self.allocation orelse return error.NoAllocation;
        if (now_ns >= value.expires_at_ns) return error.AllocationExpired;
        if (value.expires_at_ns - now_ns <= self.config.refresh_margin_ns) return .{ .refresh_due = value };
        return null;
    }
    pub fn refreshed(self: *TurnAllocationLifecycle, value: allocation.TurnAllocation, now_ns: core.TimeNs) TurnAllocationLifecycleError!void {
        _ = try self.poll(now_ns) orelse return error.RefreshNotDue;
        try self.activate(value, now_ns);
    }
    pub fn failed(self: *TurnAllocationLifecycle, failure: TurnAllocationFailure) TurnAllocationLifecycleError!TurnAllocationEvent {
        if (self.allocation == null) return error.NoAllocation;
        self.failures += 1;
        if (self.failures >= self.config.maximum_failures) {
            self.allocation = null;
            return error.FailureLimitReached;
        }
        return .{ .recoverable_failure = failure };
    }
    pub fn deallocate(self: *TurnAllocationLifecycle) TurnAllocationLifecycleError!TurnAllocationEvent {
        if (self.allocation == null) return error.NoAllocation;
        self.allocation = null;
        self.failures = 0;
        return .deallocated;
    }
};

test "TURN allocation lifecycle refreshes expires and deallocates deterministically" {
    var lifecycle = try TurnAllocationLifecycle.init(.{ .credential_expires_at_ns = 100, .refresh_margin_ns = 10, .maximum_failures = 2 });
    const value = allocation.TurnAllocation{ .relay = .{ .ipv4 = .{ .octets = .{ 1, 1, 1, 1 }, .port = 1 } }, .expires_at_ns = 50 };
    try lifecycle.activate(value, 0);
    try @import("std").testing.expect((try lifecycle.poll(39)) == null);
    try @import("std").testing.expectEqual(TurnAllocationEvent{ .refresh_due = value }, (try lifecycle.poll(40)).?);
    const refreshed = allocation.TurnAllocation{ .relay = value.relay, .expires_at_ns = 90 };
    try lifecycle.refreshed(refreshed, 40);
    try @import("std").testing.expectEqual(TurnAllocationEvent.deallocated, try lifecycle.deallocate());
    try @import("std").testing.expectError(error.NoAllocation, lifecycle.poll(41));
}

test "TURN allocation lifecycle limits failures and credential expiry" {
    var lifecycle = try TurnAllocationLifecycle.init(.{ .credential_expires_at_ns = 10, .refresh_margin_ns = 1, .maximum_failures = 2 });
    const value = allocation.TurnAllocation{ .relay = .{ .ipv4 = .{ .octets = .{ 1, 1, 1, 1 }, .port = 1 } }, .expires_at_ns = 9 };
    try lifecycle.activate(value, 0);
    try @import("std").testing.expectEqual(TurnAllocationEvent{ .recoverable_failure = .transport }, try lifecycle.failed(.transport));
    try @import("std").testing.expectError(error.FailureLimitReached, lifecycle.failed(.server_rejected));
    try @import("std").testing.expectError(error.NoAllocation, lifecycle.deallocate());
    try @import("std").testing.expectError(error.CredentialExpired, lifecycle.poll(10));
}
