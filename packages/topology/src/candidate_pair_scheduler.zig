const std = @import("std");
const core = @import("minna-san-core");
const candidates = @import("nat_candidate.zig");

pub const CandidateCheckRoute = enum { direct, relay };
pub const CandidateCheckState = enum { waiting, in_progress, succeeded, failed, expired, cancelled };
pub const CandidatePairCheck = struct {
    local: candidates.NatCandidate,
    remote: candidates.NatCandidate,
    priority: u64,
    route: CandidateCheckRoute,
    state: CandidateCheckState = .waiting,
    attempts: u8 = 0,
    next_attempt_at_ns: core.TimeNs,
    deadline_ns: ?core.TimeNs = null,
};
pub const CandidateCheckDispatch = struct { pair: usize, route: CandidateCheckRoute, attempt: u8 };
pub const CandidateCheckDiagnostic = struct {
    pair: usize,
    priority: u64,
    route: CandidateCheckRoute,
    state: CandidateCheckState,
    attempts: u8,
    next_attempt_at_ns: core.TimeNs,
    deadline_ns: ?core.TimeNs,
};
pub const CandidatePairSchedulerError = std.mem.Allocator.Error || candidates.NatCandidateError || error{ InvalidConfiguration, PairCapacityExceeded, UnknownPair, InvalidState, NoReadyCheck, OutputTooSmall, TimeOverflow };
pub const CandidatePairSchedulerConfig = struct {
    maximum_pairs: usize,
    maximum_in_flight: usize,
    maximum_attempts: u8,
    pace_interval_ns: core.TimeNs,
    retry_interval_ns: core.TimeNs,
    check_timeout_ns: core.TimeNs,
};

pub const CandidatePairScheduler = struct {
    allocator: std.mem.Allocator,
    config: CandidatePairSchedulerConfig,
    pairs: std.ArrayListUnmanaged(CandidatePairCheck) = .empty,
    next_dispatch_at_ns: core.TimeNs = 0,

    pub fn init(allocator: std.mem.Allocator, config: CandidatePairSchedulerConfig) CandidatePairSchedulerError!CandidatePairScheduler {
        if (config.maximum_pairs == 0 or config.maximum_in_flight == 0 or config.maximum_in_flight > config.maximum_pairs or config.maximum_attempts == 0 or config.pace_interval_ns == 0 or config.retry_interval_ns == 0 or config.check_timeout_ns == 0) return error.InvalidConfiguration;
        return .{ .allocator = allocator, .config = config };
    }
    pub fn deinit(self: *CandidatePairScheduler) void {
        self.pairs.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn add(self: *CandidatePairScheduler, local: candidates.NatCandidate, remote: candidates.NatCandidate, priority: u64, now_ns: core.TimeNs) CandidatePairSchedulerError!usize {
        try candidates.validate_nat_candidate(local, now_ns);
        try candidates.validate_nat_candidate(remote, now_ns);
        if (priority == 0) return error.InvalidConfiguration;
        if (self.pairs.items.len == self.config.maximum_pairs) return error.PairCapacityExceeded;
        const route: CandidateCheckRoute = if (local.kind == .relay or remote.kind == .relay) .relay else .direct;
        try self.pairs.append(self.allocator, .{ .local = local, .remote = remote, .priority = priority, .route = route, .next_attempt_at_ns = now_ns });
        return self.pairs.items.len - 1;
    }
    pub fn dispatch(self: *CandidatePairScheduler, now_ns: core.TimeNs) CandidatePairSchedulerError!CandidateCheckDispatch {
        try self.expire(now_ns);
        if (now_ns < self.next_dispatch_at_ns or self.in_flight_count() == self.config.maximum_in_flight) return error.NoReadyCheck;
        const pair = self.next_ready_pair(now_ns) orelse return error.NoReadyCheck;
        const deadline_ns = try add_time(now_ns, self.config.check_timeout_ns);
        const next_dispatch_at_ns = try add_time(now_ns, self.config.pace_interval_ns);
        const value = &self.pairs.items[pair];
        value.state = .in_progress;
        value.attempts += 1;
        value.deadline_ns = deadline_ns;
        self.next_dispatch_at_ns = next_dispatch_at_ns;
        return .{ .pair = pair, .route = value.route, .attempt = value.attempts };
    }
    pub fn complete(self: *CandidatePairScheduler, pair: usize, success: bool, now_ns: core.TimeNs) CandidatePairSchedulerError!void {
        const value = self.pair_ptr(pair) orelse return error.UnknownPair;
        if (value.state != .in_progress) return error.InvalidState;
        if (candidates.candidate_expired(value.local, now_ns) or candidates.candidate_expired(value.remote, now_ns)) {
            value.state = .expired;
            value.deadline_ns = null;
            return;
        }
        if (success) {
            value.state = .succeeded;
            value.deadline_ns = null;
            return;
        }
        try self.retry_or_fail(value, now_ns);
    }
    pub fn cancel(self: *CandidatePairScheduler, pair: usize) CandidatePairSchedulerError!void {
        const value = self.pair_ptr(pair) orelse return error.UnknownPair;
        switch (value.state) {
            .waiting, .in_progress => {},
            else => return error.InvalidState,
        }
        value.state = .cancelled;
        value.deadline_ns = null;
    }
    pub fn expire(self: *CandidatePairScheduler, now_ns: core.TimeNs) CandidatePairSchedulerError!void {
        for (self.pairs.items) |*value| {
            if (value.state == .expired or value.state == .failed or value.state == .cancelled) continue;
            if (candidates.candidate_expired(value.local, now_ns) or candidates.candidate_expired(value.remote, now_ns)) {
                value.state = .expired;
                value.deadline_ns = null;
                continue;
            }
            if (value.state == .in_progress and now_ns >= value.deadline_ns.?) try self.retry_or_fail(value, now_ns);
        }
    }
    pub fn candidate_pair(self: *const CandidatePairScheduler, index: usize) ?CandidatePairCheck {
        if (index >= self.pairs.items.len) return null;
        return self.pairs.items[index];
    }
    pub fn best_succeeded_pair(self: *const CandidatePairScheduler) ?usize {
        var selected: ?usize = null;
        for (self.pairs.items, 0..) |value, index| {
            if (value.state != .succeeded) continue;
            if (selected == null or value.priority > self.pairs.items[selected.?].priority) selected = index;
        }
        return selected;
    }
    pub fn diagnostics(self: *const CandidatePairScheduler, output: []CandidateCheckDiagnostic) CandidatePairSchedulerError![]const CandidateCheckDiagnostic {
        if (output.len < self.pairs.items.len) return error.OutputTooSmall;
        for (self.pairs.items, 0..) |value, index| {
            output[index] = .{
                .pair = index,
                .priority = value.priority,
                .route = value.route,
                .state = value.state,
                .attempts = value.attempts,
                .next_attempt_at_ns = value.next_attempt_at_ns,
                .deadline_ns = value.deadline_ns,
            };
        }
        return output[0..self.pairs.items.len];
    }
    fn retry_or_fail(self: *const CandidatePairScheduler, value: *CandidatePairCheck, now_ns: core.TimeNs) CandidatePairSchedulerError!void {
        if (value.attempts == self.config.maximum_attempts) {
            value.state = .failed;
            value.deadline_ns = null;
            return;
        }
        const next_attempt_at_ns = try add_time(now_ns, self.config.retry_interval_ns);
        value.state = .waiting;
        value.deadline_ns = null;
        value.next_attempt_at_ns = next_attempt_at_ns;
    }
    fn in_flight_count(self: CandidatePairScheduler) usize {
        var count: usize = 0;
        for (self.pairs.items) |value| {
            if (value.state == .in_progress) count += 1;
        }
        return count;
    }
    fn next_ready_pair(self: CandidatePairScheduler, now_ns: core.TimeNs) ?usize {
        var selected: ?usize = null;
        for (self.pairs.items, 0..) |value, index| {
            if (value.state != .waiting or now_ns < value.next_attempt_at_ns) continue;
            if (selected == null or value.priority > self.pairs.items[selected.?].priority) selected = index;
        }
        return selected;
    }
    fn pair_ptr(self: *CandidatePairScheduler, index: usize) ?*CandidatePairCheck {
        if (index >= self.pairs.items.len) return null;
        return &self.pairs.items[index];
    }
};

fn add_time(now_ns: core.TimeNs, duration_ns: core.TimeNs) CandidatePairSchedulerError!core.TimeNs {
    return std.math.add(core.TimeNs, now_ns, duration_ns) catch error.TimeOverflow;
}

fn candidate(kind: candidates.NatCandidateKind, expires_at_ns: core.TimeNs) candidates.NatCandidate {
    return .{ .kind = kind, .transport = .udp, .address = .{ .ipv4 = .{ .octets = .{ 1, 1, 1, 1 }, .port = 1 } }, .priority = 1, .expires_at_ns = expires_at_ns, .credentials = if (kind == .relay) .{ .username = "u", .password = "p", .expires_at_ns = expires_at_ns } else null };
}

test "candidate-pair scheduler prioritizes relay and direct checks with pacing and caps" {
    var scheduler = try CandidatePairScheduler.init(std.testing.allocator, .{ .maximum_pairs = 2, .maximum_in_flight = 1, .maximum_attempts = 2, .pace_interval_ns = 10, .retry_interval_ns = 5, .check_timeout_ns = 20 });
    defer scheduler.deinit();
    const direct = try scheduler.add(candidate(.host, 100), candidate(.host, 100), 10, 0);
    const relay = try scheduler.add(candidate(.relay, 100), candidate(.host, 100), 20, 0);
    try std.testing.expectEqual(CandidateCheckDispatch{ .pair = relay, .route = .relay, .attempt = 1 }, try scheduler.dispatch(0));
    try std.testing.expectError(error.NoReadyCheck, scheduler.dispatch(1));
    try scheduler.complete(relay, true, 1);
    try std.testing.expectError(error.NoReadyCheck, scheduler.dispatch(9));
    try std.testing.expectEqual(CandidateCheckDispatch{ .pair = direct, .route = .direct, .attempt = 1 }, try scheduler.dispatch(10));
    try scheduler.complete(direct, true, 10);
    try std.testing.expectEqual(CandidateCheckState.succeeded, scheduler.candidate_pair(relay).?.state);
    try std.testing.expectEqual(CandidateCheckState.succeeded, scheduler.candidate_pair(direct).?.state);
}

test "candidate-pair scheduler retries failures and expires stale pairs" {
    var scheduler = try CandidatePairScheduler.init(std.testing.allocator, .{ .maximum_pairs = 1, .maximum_in_flight = 1, .maximum_attempts = 2, .pace_interval_ns = 1, .retry_interval_ns = 5, .check_timeout_ns = 3 });
    defer scheduler.deinit();
    const pair = try scheduler.add(candidate(.host, 20), candidate(.host, 20), 1, 0);
    _ = try scheduler.dispatch(0);
    try scheduler.complete(pair, false, 1);
    try std.testing.expectError(error.NoReadyCheck, scheduler.dispatch(5));
    try std.testing.expectEqual(@as(u8, 2), (try scheduler.dispatch(6)).attempt);
    try scheduler.expire(9);
    try std.testing.expectEqual(CandidateCheckState.failed, scheduler.candidate_pair(pair).?.state);

    var stale = try CandidatePairScheduler.init(std.testing.allocator, .{ .maximum_pairs = 1, .maximum_in_flight = 1, .maximum_attempts = 1, .pace_interval_ns = 1, .retry_interval_ns = 1, .check_timeout_ns = 10 });
    defer stale.deinit();
    _ = try stale.add(candidate(.host, 5), candidate(.host, 5), 1, 0);
    _ = try stale.dispatch(0);
    try stale.expire(5);
    try std.testing.expectEqual(CandidateCheckState.expired, stale.candidate_pair(0).?.state);
    try std.testing.expectError(error.NoReadyCheck, stale.dispatch(5));
}

test "candidate-pair scheduler cancels checks and selects the highest viable pair deterministically" {
    var scheduler = try CandidatePairScheduler.init(std.testing.allocator, .{ .maximum_pairs = 3, .maximum_in_flight = 1, .maximum_attempts = 1, .pace_interval_ns = 1, .retry_interval_ns = 1, .check_timeout_ns = 5 });
    defer scheduler.deinit();
    const cancelled = try scheduler.add(candidate(.host, 100), candidate(.host, 100), 30, 0);
    const high = try scheduler.add(candidate(.host, 100), candidate(.host, 100), 20, 0);
    const low = try scheduler.add(candidate(.host, 100), candidate(.host, 100), 10, 0);
    try scheduler.cancel(cancelled);
    try std.testing.expectEqual(CandidateCheckDispatch{ .pair = high, .route = .direct, .attempt = 1 }, try scheduler.dispatch(0));
    try scheduler.complete(high, true, 0);
    try std.testing.expectEqual(CandidateCheckDispatch{ .pair = low, .route = .direct, .attempt = 1 }, try scheduler.dispatch(1));
    try scheduler.complete(low, true, 1);
    try std.testing.expectEqual(high, scheduler.best_succeeded_pair().?);
    var diagnostics: [3]CandidateCheckDiagnostic = undefined;
    const values = try scheduler.diagnostics(&diagnostics);
    try std.testing.expectEqual(CandidateCheckState.cancelled, values[cancelled].state);
    try std.testing.expectEqual(CandidateCheckState.succeeded, values[high].state);
    try std.testing.expectEqual(@as(u8, 1), values[low].attempts);
    var too_small: [2]CandidateCheckDiagnostic = undefined;
    try std.testing.expectError(error.OutputTooSmall, scheduler.diagnostics(&too_small));
    try std.testing.expectError(error.InvalidState, scheduler.cancel(high));
}
