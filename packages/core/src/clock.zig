const std = @import("std");

pub const TimeNs = u64;
pub const ClockError = error{ ClockRegression, TimeOverflow };

pub const Clock = struct {
    context: *anyopaque,
    now_fn: *const fn (*anyopaque) TimeNs,

    pub fn now(self: Clock) TimeNs {
        return self.now_fn(self.context);
    }
};

pub const CheckedClock = struct {
    source: Clock,
    last_ns: ?TimeNs = null,

    pub fn init(source: Clock) CheckedClock {
        return .{ .source = source };
    }

    pub fn now(self: *CheckedClock) ClockError!TimeNs {
        const current_ns = self.source.now();
        if (self.last_ns) |last_ns| {
            if (current_ns < last_ns) return error.ClockRegression;
        }
        self.last_ns = current_ns;
        return current_ns;
    }
};

pub const ManualClock = struct {
    now_ns: TimeNs,

    pub fn init(now_ns: TimeNs) ManualClock {
        return .{ .now_ns = now_ns };
    }

    pub fn clock(self: *ManualClock) Clock {
        return .{ .context = self, .now_fn = now };
    }

    pub fn advance(self: *ManualClock, delta_ns: TimeNs) ClockError!void {
        self.now_ns = std.math.add(TimeNs, self.now_ns, delta_ns) catch return error.TimeOverflow;
    }

    fn now(context: *anyopaque) TimeNs {
        const self: *ManualClock = @ptrCast(@alignCast(context));
        return self.now_ns;
    }
};

test "manual clocks support deterministic monotonic polling" {
    var manual = ManualClock.init(10);
    var checked = CheckedClock.init(manual.clock());
    try std.testing.expectEqual(@as(TimeNs, 10), try checked.now());
    try manual.advance(5);
    try std.testing.expectEqual(@as(TimeNs, 15), try checked.now());
}

test "checked clocks reject replay regressions and overflow" {
    const Sequence = struct {
        values: []const TimeNs,
        index: usize = 0,

        fn clock(self: *@This()) Clock {
            return .{ .context = self, .now_fn = now };
        }

        fn now(context: *anyopaque) TimeNs {
            const self: *@This() = @ptrCast(@alignCast(context));
            defer self.index += 1;
            return self.values[self.index];
        }
    };
    var sequence = Sequence{ .values = &.{ 2, 1 } };
    var checked = CheckedClock.init(sequence.clock());
    _ = try checked.now();
    try std.testing.expectError(error.ClockRegression, checked.now());
    var manual = ManualClock.init(std.math.maxInt(TimeNs));
    try std.testing.expectError(error.TimeOverflow, manual.advance(1));
}
