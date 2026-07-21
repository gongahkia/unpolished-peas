const std = @import("std");
const core = @import("minna-san-core");
const topology = @import("minna-san-topology");
const transport = @import("minna-san-transport");
const resource = @import("resource_handle.zig");
const timer_wheel = @import("timer_wheel.zig");

pub const TransportRetryState = enum { active, cooling_down, terminal, cancelled };
pub const TransportRetryConfig = struct {
    maximum_attempts: u8,
    initial_cooldown_ns: core.TimeNs,
    maximum_cooldown_ns: core.TimeNs,

    pub fn validate(self: TransportRetryConfig) TransportRetryControllerError!void {
        if (self.maximum_attempts == 0 or self.initial_cooldown_ns == 0 or self.maximum_cooldown_ns < self.initial_cooldown_ns) return error.InvalidConfiguration;
    }
};
pub const TransportRetryStatus = struct {
    state: TransportRetryState,
    attempts: u8,
    timer: ?timer_wheel.TimerId,
};
pub const TransportRetryEvent = union(enum) {
    retry_scheduled: struct { session: *resource.ResourceHandle, candidate_id: u64, attempt: u8, deadline_ns: core.TimeNs, timer: timer_wheel.TimerId, failure: transport.TransportIoFailure },
    retry_ready: struct { session: *resource.ResourceHandle, candidate_id: u64, attempt: u8 },
    terminal_failure: struct { session: *resource.ResourceHandle, candidate_id: u64, attempt: u8, failure: transport.TransportIoFailure },
    cancelled: struct { session: *resource.ResourceHandle, candidate_id: u64 },
};
pub const TransportRetryControllerError = std.mem.Allocator.Error || timer_wheel.TimerWheelError || topology.RouteCandidateSelectionError || error{ InvalidConfiguration, CapacityExceeded, AlreadyRegistered, UnknownSession, InvalidState, CooldownPending, TimeOverflow };

const Entry = struct {
    session: *resource.ResourceHandle,
    candidate_id: u64,
    config: TransportRetryConfig,
    state: TransportRetryState = .active,
    attempts: u8 = 0,
    timer: ?timer_wheel.TimerId = null,
};

pub const TransportRetryController = struct {
    allocator: std.mem.Allocator,
    capacity: usize,
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) TransportRetryControllerError!TransportRetryController {
        if (capacity == 0 or capacity > core.max_session_capacity) return error.InvalidConfiguration;
        return .{ .allocator = allocator, .capacity = capacity };
    }

    pub fn deinit(self: *TransportRetryController) void {
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn register(self: *TransportRetryController, session: *resource.ResourceHandle, candidate: topology.RouteCandidate, policy: topology.RouteCandidatePolicy, config: TransportRetryConfig) TransportRetryControllerError!void {
        try config.validate();
        if (self.entries.items.len >= self.capacity) return error.CapacityExceeded;
        for (self.entries.items) |entry| if (entry.session == session) return error.AlreadyRegistered;
        try validateCandidate(candidate, policy);
        try self.entries.append(self.allocator, .{ .session = session, .candidate_id = candidate.id, .config = config });
    }

    pub fn recordFailure(self: *TransportRetryController, timers: *timer_wheel.TimerWheel, session: *resource.ResourceHandle, failure: transport.TransportIoFailure, now_ns: core.TimeNs) TransportRetryControllerError!TransportRetryEvent {
        const entry = try self.lookup(session);
        switch (entry.state) {
            .cooling_down => return error.CooldownPending,
            .terminal, .cancelled => return error.InvalidState,
            .active => {},
        }
        const attempt = std.math.add(u8, entry.attempts, 1) catch return error.InvalidConfiguration;
        if (failure.retry == .never or attempt >= entry.config.maximum_attempts) {
            entry.attempts = attempt;
            entry.state = .terminal;
            return .{ .terminal_failure = .{ .session = session, .candidate_id = entry.candidate_id, .attempt = attempt, .failure = failure } };
        }
        const cooldown_ns = try cooldown(entry.config, attempt, failure.retry);
        const deadline_ns = std.math.add(core.TimeNs, now_ns, cooldown_ns) catch return error.TimeOverflow;
        const timer = try timers.schedule(.retransmission, deadline_ns);
        entry.attempts = attempt;
        entry.timer = timer;
        entry.state = .cooling_down;
        return .{ .retry_scheduled = .{ .session = session, .candidate_id = entry.candidate_id, .attempt = attempt, .deadline_ns = deadline_ns, .timer = timer, .failure = failure } };
    }

    pub fn onTimer(self: *TransportRetryController, timer: timer_wheel.Timer) TransportRetryControllerError!?TransportRetryEvent {
        if (timer.kind != .retransmission) return null;
        for (self.entries.items) |*entry| {
            if (entry.timer != timer.id) continue;
            if (entry.state != .cooling_down) return null;
            entry.timer = null;
            entry.state = .active;
            return .{ .retry_ready = .{ .session = entry.session, .candidate_id = entry.candidate_id, .attempt = entry.attempts } };
        }
        return null;
    }

    pub fn cancel(self: *TransportRetryController, timers: *timer_wheel.TimerWheel, session: *resource.ResourceHandle) TransportRetryControllerError!TransportRetryEvent {
        const entry = try self.lookup(session);
        switch (entry.state) {
            .terminal, .cancelled => return error.InvalidState,
            .active, .cooling_down => {},
        }
        if (entry.timer) |timer| try timers.cancel(timer);
        entry.timer = null;
        entry.state = .cancelled;
        return .{ .cancelled = .{ .session = session, .candidate_id = entry.candidate_id } };
    }

    pub fn status(self: *TransportRetryController, session: *resource.ResourceHandle) TransportRetryControllerError!TransportRetryStatus {
        const entry = try self.lookup(session);
        return .{ .state = entry.state, .attempts = entry.attempts, .timer = entry.timer };
    }

    pub fn forget(self: *TransportRetryController, timers: *timer_wheel.TimerWheel, session: *resource.ResourceHandle) void {
        for (self.entries.items, 0..) |entry, index| {
            if (entry.session != session) continue;
            if (entry.timer) |timer| timers.cancel(timer) catch {};
            _ = self.entries.orderedRemove(index);
            return;
        }
    }

    fn lookup(self: *TransportRetryController, session: *resource.ResourceHandle) TransportRetryControllerError!*Entry {
        for (self.entries.items) |*entry| if (entry.session == session) return entry;
        return error.UnknownSession;
    }
};

fn validateCandidate(candidate: topology.RouteCandidate, policy: topology.RouteCandidatePolicy) TransportRetryControllerError!void {
    const selector = try topology.RouteCandidateSelector.init(policy);
    const candidates = [_]topology.RouteCandidate{candidate};
    var decisions: [1]topology.RouteCandidateDecision = undefined;
    _ = try selector.select(candidates[0..], decisions[0..]);
}

fn cooldown(config: TransportRetryConfig, attempt: u8, retry: transport.TransportRetryHint) TransportRetryControllerError!core.TimeNs {
    if (retry == .immediate) return config.initial_cooldown_ns;
    var value = config.initial_cooldown_ns;
    var exponent: u8 = 1;
    while (exponent < attempt and value < config.maximum_cooldown_ns) : (exponent += 1) {
        value = std.math.mul(core.TimeNs, value, 2) catch config.maximum_cooldown_ns;
        value = @min(value, config.maximum_cooldown_ns);
    }
    return value;
}

test "transport retry controllers use cooldown timers and terminate without poll spinning" {
    var timers = try timer_wheel.TimerWheel.init(std.testing.allocator, 2);
    defer timers.deinit();
    var retries = try TransportRetryController.init(std.testing.allocator, 1);
    defer retries.deinit();
    const session: *resource.ResourceHandle = @ptrFromInt(1);
    const candidate = topology.RouteCandidate{ .id = 1, .transport = .udp, .endpoint = transport.Endpoint.from_ipv4(.{ .octets = .{ 127, 0, 0, 1 }, .port = 9000 }), .negotiated = true, .health = .healthy };
    try retries.register(session, candidate, .{ .allowed_transport_bits = topology.route_transport_bit(.udp) }, .{ .maximum_attempts = 3, .initial_cooldown_ns = 5, .maximum_cooldown_ns = 20 });
    const failure = transport.normalize_io_failure(error.ConnectionResetByPeer);
    const first = try retries.recordFailure(&timers, session, failure, 0);
    try std.testing.expectEqual(@as(core.TimeNs, 5), first.retry_scheduled.deadline_ns);
    try std.testing.expectError(error.CooldownPending, retries.recordFailure(&timers, session, failure, 0));
    try std.testing.expect((try timers.advance(4)) == null);
    const first_timer = (try timers.advance(5)).?;
    try std.testing.expectEqual(@as(u8, 1), (try retries.onTimer(first_timer)).?.retry_ready.attempt);
    const second = try retries.recordFailure(&timers, session, failure, 5);
    try std.testing.expectEqual(@as(core.TimeNs, 15), second.retry_scheduled.deadline_ns);
    const second_timer = (try timers.advance(15)).?;
    _ = try retries.onTimer(second_timer);
    const terminal = try retries.recordFailure(&timers, session, failure, 15);
    try std.testing.expectEqual(@as(u8, 3), terminal.terminal_failure.attempt);
    try std.testing.expectEqual(TransportRetryState.terminal, (try retries.status(session)).state);
    try std.testing.expect((try timers.advance(100)) == null);
}

test "transport retry controllers cancel pending timers and reject stale route policy" {
    var timers = try timer_wheel.TimerWheel.init(std.testing.allocator, 1);
    defer timers.deinit();
    var retries = try TransportRetryController.init(std.testing.allocator, 1);
    defer retries.deinit();
    const session: *resource.ResourceHandle = @ptrFromInt(1);
    const candidate = topology.RouteCandidate{ .id = 1, .transport = .tcp, .endpoint = transport.Endpoint.from_ipv4(.{ .octets = .{ 127, 0, 0, 1 }, .port = 9000 }), .negotiated = true, .health = .healthy };
    try std.testing.expectError(error.NoRoute, retries.register(session, candidate, .{ .allowed_transport_bits = topology.route_transport_bit(.udp) }, .{ .maximum_attempts = 2, .initial_cooldown_ns = 1, .maximum_cooldown_ns = 1 }));
    try retries.register(session, candidate, .{ .allowed_transport_bits = topology.route_transport_bit(.tcp) }, .{ .maximum_attempts = 2, .initial_cooldown_ns = 1, .maximum_cooldown_ns = 1 });
    _ = try retries.recordFailure(&timers, session, transport.normalize_io_failure(error.ConnectionResetByPeer), 0);
    _ = try retries.cancel(&timers, session);
    try std.testing.expectEqual(TransportRetryState.cancelled, (try retries.status(session)).state);
    try std.testing.expect((try timers.advance(1)) == null);
}
