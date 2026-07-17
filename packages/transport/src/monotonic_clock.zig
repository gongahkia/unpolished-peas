const std = @import("std");
const core = @import("minna-san-core");

pub const DesktopMonotonicClockError = error{Unsupported};
pub const TransportDeadlineError = error{TimeOverflow};

pub const DesktopMonotonicClock = struct {
    origin: std.time.Instant,

    pub fn init() DesktopMonotonicClockError!DesktopMonotonicClock {
        return .{ .origin = std.time.Instant.now() catch return error.Unsupported };
    }

    pub fn clock(self: *DesktopMonotonicClock) core.Clock {
        return .{ .context = self, .now_fn = now };
    }

    fn now(context: *anyopaque) core.TimeNs {
        const self: *DesktopMonotonicClock = @ptrCast(@alignCast(context));
        const current = std.time.Instant.now() catch unreachable;
        return current.since(self.origin);
    }
};

pub const TransportDeadline = struct {
    deadline_ns: core.TimeNs,

    pub fn start(clock: core.Clock, duration_ns: core.TimeNs) TransportDeadlineError!TransportDeadline {
        return .{ .deadline_ns = std.math.add(core.TimeNs, clock.now(), duration_ns) catch return error.TimeOverflow };
    }

    pub fn expired(self: TransportDeadline, clock: core.Clock) bool {
        return clock.now() >= self.deadline_ns;
    }

    pub fn remaining(self: TransportDeadline, clock: core.Clock) core.TimeNs {
        return self.deadline_ns -| clock.now();
    }
};

test "desktop monotonic clocks advance without wall-clock timestamps" {
    var source = try DesktopMonotonicClock.init();
    const clock = source.clock();
    const first = clock.now();
    std.Thread.sleep(std.time.ns_per_ms);
    try std.testing.expect(clock.now() >= first);
}

test "transport deadlines use provided monotonic clocks and detect overflow" {
    var manual = core.ManualClock.init(10);
    const clock = manual.clock();
    const deadline = try TransportDeadline.start(clock, 5);
    try std.testing.expectEqual(@as(core.TimeNs, 5), deadline.remaining(clock));
    try manual.advance(5);
    try std.testing.expect(deadline.expired(clock));
    var overflowing = core.ManualClock.init(std.math.maxInt(core.TimeNs));
    try std.testing.expectError(error.TimeOverflow, TransportDeadline.start(overflowing.clock(), 1));
}
