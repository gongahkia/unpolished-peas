const std = @import("std");
const core = @import("minna-san-core");

pub const TimerKind = enum(u8) { session, retransmission, keepalive, service };
pub const TimerId = u64;
pub const Timer = struct { id: TimerId, kind: TimerKind, deadline_ns: core.TimeNs };
pub const TimerWheelError = std.mem.Allocator.Error || error{ InvalidConfiguration, DeadlineInPast, TimerCapacityExceeded, UnknownTimer, TimeRegression };

pub const TimerWheel = struct {
    allocator: std.mem.Allocator,
    capacity: usize,
    now_ns: core.TimeNs = 0,
    next_id: TimerId = 1,
    timers: std.ArrayListUnmanaged(Timer) = .empty,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) TimerWheelError!TimerWheel {
        if (capacity == 0) return error.InvalidConfiguration;
        return .{ .allocator = allocator, .capacity = capacity };
    }

    pub fn deinit(self: *TimerWheel) void {
        self.timers.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn schedule(self: *TimerWheel, kind: TimerKind, deadline_ns: core.TimeNs) TimerWheelError!TimerId {
        if (deadline_ns < self.now_ns) return error.DeadlineInPast;
        if (self.timers.items.len >= self.capacity) return error.TimerCapacityExceeded;
        const id = self.next_id;
        self.next_id +%= 1;
        if (self.next_id == 0) self.next_id = 1;
        try self.timers.append(self.allocator, .{ .id = id, .kind = kind, .deadline_ns = deadline_ns });
        return id;
    }

    pub fn cancel(self: *TimerWheel, id: TimerId) TimerWheelError!void {
        for (self.timers.items, 0..) |timer, index| {
            if (timer.id != id) continue;
            _ = self.timers.orderedRemove(index);
            return;
        }
        return error.UnknownTimer;
    }

    pub fn advance(self: *TimerWheel, now_ns: core.TimeNs) TimerWheelError!?Timer {
        if (now_ns < self.now_ns) return error.TimeRegression;
        self.now_ns = now_ns;
        var selected: ?usize = null;
        for (self.timers.items, 0..) |timer, index| {
            if (timer.deadline_ns > now_ns) continue;
            if (selected == null or timer.deadline_ns < self.timers.items[selected.?].deadline_ns) selected = index;
        }
        return if (selected) |index| self.timers.orderedRemove(index) else null;
    }

    pub fn nextDeadline(self: *const TimerWheel) ?core.TimeNs {
        var next: ?core.TimeNs = null;
        for (self.timers.items) |timer| {
            if (next == null or timer.deadline_ns < next.?) next = timer.deadline_ns;
        }
        return next;
    }
};

test "manual timer wheels fire ordered deadlines never early" {
    var wheel = try TimerWheel.init(std.testing.allocator, 4);
    defer wheel.deinit();
    const service = try wheel.schedule(.service, 10);
    const session = try wheel.schedule(.session, 5);
    _ = service;
    try std.testing.expect((try wheel.advance(4)) == null);
    const first = (try wheel.advance(5)).?;
    try std.testing.expectEqual(session, first.id);
    try std.testing.expectEqual(TimerKind.session, first.kind);
    try std.testing.expect((try wheel.advance(9)) == null);
    try std.testing.expectEqual(@as(core.TimeNs, 10), wheel.nextDeadline().?);
    try std.testing.expectEqual(TimerKind.service, (try wheel.advance(10)).?.kind);
}

test "timer wheels bound cancellation and clock regressions" {
    var wheel = try TimerWheel.init(std.testing.allocator, 1);
    defer wheel.deinit();
    const timer = try wheel.schedule(.keepalive, 1);
    try std.testing.expectError(error.TimerCapacityExceeded, wheel.schedule(.retransmission, 2));
    try wheel.cancel(timer);
    try std.testing.expectError(error.UnknownTimer, wheel.cancel(timer));
    _ = try wheel.advance(3);
    try std.testing.expectError(error.TimeRegression, wheel.advance(2));
}
