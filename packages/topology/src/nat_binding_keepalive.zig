const std = @import("std");
const core = @import("minna-san-core");

pub const NatBindingKind = enum { host, stun, relay };
pub const NatBindingState = enum { active, failed, idle };
pub const NatBindingKeepalive = struct {
    kind: NatBindingKind,
    state: NatBindingState = .active,
    failures: u8 = 0,
    last_activity_at_ns: core.TimeNs,
    next_due_at_ns: core.TimeNs,
};
pub const NatKeepaliveEvent = struct { kind: NatBindingKind, success: bool, retired: bool };
pub const NatKeepaliveIo = struct {
    context: *anyopaque,
    send_fn: *const fn (*anyopaque, NatBindingKind) bool,
    pub fn send(self: NatKeepaliveIo, kind: NatBindingKind) bool {
        return self.send_fn(self.context, kind);
    }
};
pub const NatBindingKeepaliveError = error{ InvalidConfiguration, BindingNotActive, TimeOverflow };
pub const NatBindingKeepaliveConfig = struct {
    interval_ns: core.TimeNs,
    retry_interval_ns: core.TimeNs,
    maximum_failures: u8,
    maximum_sends_per_poll: u8,
    idle_timeout_ns: core.TimeNs = 0,
    io: NatKeepaliveIo,
};

pub const NatBindingKeepalives = struct {
    config: NatBindingKeepaliveConfig,
    bindings: [3]?NatBindingKeepalive = .{null} ** 3,

    pub fn init(config: NatBindingKeepaliveConfig) NatBindingKeepaliveError!NatBindingKeepalives {
        if (config.interval_ns == 0 or config.retry_interval_ns == 0 or config.maximum_failures == 0 or config.maximum_sends_per_poll == 0 or config.maximum_sends_per_poll > 3) return error.InvalidConfiguration;
        return .{ .config = config };
    }
    pub fn activate(self: *NatBindingKeepalives, kind: NatBindingKind, now_ns: core.TimeNs) void {
        self.bindings[binding_index(kind)] = .{ .kind = kind, .last_activity_at_ns = now_ns, .next_due_at_ns = now_ns };
    }
    pub fn deactivate(self: *NatBindingKeepalives, kind: NatBindingKind) NatBindingKeepaliveError!void {
        if (self.bindings[binding_index(kind)] == null) return error.BindingNotActive;
        self.bindings[binding_index(kind)] = null;
    }
    pub fn record_activity(self: *NatBindingKeepalives, kind: NatBindingKind, now_ns: core.TimeNs) NatBindingKeepaliveError!void {
        const binding = if (self.bindings[binding_index(kind)]) |*active| active else return error.BindingNotActive;
        if (binding.state != .active) return error.BindingNotActive;
        binding.failures = 0;
        binding.last_activity_at_ns = now_ns;
        binding.next_due_at_ns = try add_time(now_ns, self.config.interval_ns);
    }
    pub fn poll(self: *NatBindingKeepalives, now_ns: core.TimeNs, output: []NatKeepaliveEvent) NatBindingKeepaliveError!usize {
        _ = self.shutdown_idle(now_ns);
        var count: usize = 0;
        const maximum = @min(output.len, @as(usize, self.config.maximum_sends_per_poll));
        for (&self.bindings) |*slot| {
            if (count == maximum) break;
            const binding = if (slot.*) |*active| active else continue;
            if (binding.state != .active or now_ns < binding.next_due_at_ns) continue;
            const interval_due_at_ns = try add_time(now_ns, self.config.interval_ns);
            const retry_due_at_ns = try add_time(now_ns, self.config.retry_interval_ns);
            const success = self.config.io.send(binding.kind);
            if (success) {
                binding.failures = 0;
                binding.next_due_at_ns = interval_due_at_ns;
                output[count] = .{ .kind = binding.kind, .success = true, .retired = false };
            } else {
                binding.failures += 1;
                const retired = binding.failures == self.config.maximum_failures;
                binding.state = if (retired) .failed else .active;
                binding.next_due_at_ns = retry_due_at_ns;
                output[count] = .{ .kind = binding.kind, .success = false, .retired = retired };
            }
            count += 1;
        }
        return count;
    }
    pub fn shutdown_idle(self: *NatBindingKeepalives, now_ns: core.TimeNs) usize {
        if (self.config.idle_timeout_ns == 0) return 0;
        var count: usize = 0;
        for (&self.bindings) |*slot| {
            const binding = if (slot.*) |*active| active else continue;
            if (binding.state != .active or now_ns < binding.last_activity_at_ns or now_ns - binding.last_activity_at_ns < self.config.idle_timeout_ns) continue;
            binding.state = .idle;
            count += 1;
        }
        return count;
    }
    pub fn binding_state(self: *const NatBindingKeepalives, kind: NatBindingKind) ?NatBindingKeepalive {
        return self.bindings[binding_index(kind)];
    }
};

fn binding_index(kind: NatBindingKind) usize {
    return @intFromEnum(kind);
}

fn add_time(now_ns: core.TimeNs, duration_ns: core.TimeNs) NatBindingKeepaliveError!core.TimeNs {
    return std.math.add(core.TimeNs, now_ns, duration_ns) catch error.TimeOverflow;
}

test "NAT binding keepalives bound host STUN relay sends and reset after success" {
    const Fixture = struct {
        sends: usize = 0,
        fn send(context: *anyopaque, _: NatBindingKind) bool {
            @as(*@This(), @ptrCast(@alignCast(context))).sends += 1;
            return true;
        }
    };
    var fixture = Fixture{};
    var keepalives = try NatBindingKeepalives.init(.{ .interval_ns = 10, .retry_interval_ns = 2, .maximum_failures = 2, .maximum_sends_per_poll = 2, .io = .{ .context = &fixture, .send_fn = Fixture.send } });
    keepalives.activate(.host, 0);
    keepalives.activate(.stun, 0);
    keepalives.activate(.relay, 0);
    var events: [2]NatKeepaliveEvent = undefined;
    try std.testing.expectEqual(@as(usize, 2), try keepalives.poll(0, events[0..]));
    try std.testing.expectEqual(NatBindingKind.host, events[0].kind);
    try std.testing.expectEqual(NatBindingKind.stun, events[1].kind);
    try std.testing.expectEqual(@as(usize, 1), try keepalives.poll(1, events[0..]));
    try std.testing.expectEqual(NatBindingKind.relay, events[0].kind);
    try std.testing.expectEqual(@as(usize, 3), fixture.sends);
    try std.testing.expectEqual(@as(usize, 0), try keepalives.poll(9, events[0..]));
    try keepalives.record_activity(.host, 10);
    try std.testing.expectEqual(@as(usize, 1), try keepalives.poll(10, events[0..]));
    try std.testing.expectEqual(NatBindingKind.stun, events[0].kind);
    try std.testing.expectEqual(NatBindingState.active, keepalives.binding_state(.host).?.state);
}

test "NAT binding keepalives retry failures then retire and deactivate bindings" {
    const Fixture = struct {
        fn send(_: *anyopaque, _: NatBindingKind) bool {
            return false;
        }
    };
    var fixture = Fixture{};
    var keepalives = try NatBindingKeepalives.init(.{ .interval_ns = 10, .retry_interval_ns = 3, .maximum_failures = 2, .maximum_sends_per_poll = 1, .io = .{ .context = &fixture, .send_fn = Fixture.send } });
    keepalives.activate(.host, 0);
    var events: [1]NatKeepaliveEvent = undefined;
    try std.testing.expectEqual(@as(usize, 1), try keepalives.poll(0, events[0..]));
    try std.testing.expect(!events[0].retired);
    try std.testing.expectEqual(@as(usize, 0), try keepalives.poll(2, events[0..]));
    try std.testing.expectEqual(@as(usize, 1), try keepalives.poll(3, events[0..]));
    try std.testing.expect(events[0].retired);
    try std.testing.expectEqual(NatBindingState.failed, keepalives.binding_state(.host).?.state);
    try std.testing.expectEqual(@as(usize, 0), try keepalives.poll(6, events[0..]));
    try keepalives.deactivate(.host);
    try std.testing.expectError(error.BindingNotActive, keepalives.deactivate(.host));
}

test "NAT binding keepalives stop after idle shutdown and route close without exceeding the send cap" {
    const Fixture = struct {
        sends: usize = 0,
        fn send(context: *anyopaque, _: NatBindingKind) bool {
            @as(*@This(), @ptrCast(@alignCast(context))).sends += 1;
            return true;
        }
    };
    var fixture = Fixture{};
    var keepalives = try NatBindingKeepalives.init(.{ .interval_ns = 2, .retry_interval_ns = 1, .maximum_failures = 1, .maximum_sends_per_poll = 1, .idle_timeout_ns = 5, .io = .{ .context = &fixture, .send_fn = Fixture.send } });
    keepalives.activate(.host, 0);
    keepalives.activate(.relay, 0);
    var events: [1]NatKeepaliveEvent = undefined;
    try std.testing.expectEqual(@as(usize, 1), try keepalives.poll(0, events[0..]));
    try std.testing.expectEqual(@as(usize, 1), fixture.sends);
    try keepalives.deactivate(.relay);
    try std.testing.expectEqual(@as(usize, 1), keepalives.shutdown_idle(5));
    try std.testing.expectEqual(NatBindingState.idle, keepalives.binding_state(.host).?.state);
    try std.testing.expectEqual(@as(usize, 0), try keepalives.poll(10, events[0..]));
    try std.testing.expectEqual(@as(usize, 1), fixture.sends);
    try std.testing.expectError(error.BindingNotActive, keepalives.record_activity(.host, 10));
}
