const std = @import("std");
const core = @import("minna-san-core");
const topology = @import("minna-san-topology");
const timer_wheel = @import("timer_wheel.zig");

pub const max_turn_allocation_refreshes: usize = core.max_session_capacity;
pub const TurnAllocationRefreshSchedulerError = std.mem.Allocator.Error || timer_wheel.TimerWheelError || topology.TurnAllocationLifecycleError || error{ InvalidConfiguration, RefreshCapacityExceeded, StaleRefresh, RefreshNotDue };
pub const TurnAllocationRefreshSchedulerConfig = struct {
    maximum_allocations: usize = 64,
    refresh_margin_ns: core.TimeNs,
    retry_delay_ns: core.TimeNs,
    maximum_failures: usize,

    pub fn validate(self: TurnAllocationRefreshSchedulerConfig) TurnAllocationRefreshSchedulerError!void {
        if (self.maximum_allocations == 0 or self.maximum_allocations > max_turn_allocation_refreshes or self.refresh_margin_ns == 0 or self.retry_delay_ns == 0 or self.maximum_failures == 0) return error.InvalidConfiguration;
    }
};
pub const TurnAllocationRefreshConfig = struct {
    allocation: topology.TurnAllocation,
    credential_expires_at_ns: core.TimeNs,
};
pub const TurnAllocationRefreshHandle = struct { slot: u32, generation: u32 };
pub const TurnAllocationRefreshEvent = union(enum) {
    refresh_due: struct { handle: TurnAllocationRefreshHandle, allocation: topology.TurnAllocation },
    recoverable_failure: struct { handle: TurnAllocationRefreshHandle, failure: topology.TurnAllocationFailure, retry_at_ns: core.TimeNs },
    released: TurnAllocationRefreshHandle,
};

const Entry = struct {
    lifecycle: topology.TurnAllocationLifecycle,
    timer: ?timer_wheel.TimerId = null,
};
const Slot = struct {
    generation: u32 = 1,
    entry: ?Entry = null,
};

pub const TurnAllocationRefreshScheduler = struct {
    allocator: std.mem.Allocator,
    config: TurnAllocationRefreshSchedulerConfig,
    slots: []Slot,

    pub fn init(allocator: std.mem.Allocator, config: TurnAllocationRefreshSchedulerConfig) TurnAllocationRefreshSchedulerError!TurnAllocationRefreshScheduler {
        try config.validate();
        const slots = try allocator.alloc(Slot, config.maximum_allocations);
        for (slots) |*slot| slot.* = .{};
        return .{ .allocator = allocator, .config = config, .slots = slots };
    }

    pub fn deinit(self: *TurnAllocationRefreshScheduler, timers: *timer_wheel.TimerWheel) void {
        for (self.slots) |*slot| if (slot.entry) |*entry| if (entry.timer) |timer| timers.cancel(timer) catch {};
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    pub fn activate(self: *TurnAllocationRefreshScheduler, timers: *timer_wheel.TimerWheel, config_value: TurnAllocationRefreshConfig, now_ns: core.TimeNs) TurnAllocationRefreshSchedulerError!TurnAllocationRefreshHandle {
        const index = self.freeSlot() orelse return error.RefreshCapacityExceeded;
        var lifecycle = try topology.TurnAllocationLifecycle.init(.{ .credential_expires_at_ns = config_value.credential_expires_at_ns, .refresh_margin_ns = self.config.refresh_margin_ns, .maximum_failures = self.config.maximum_failures });
        try lifecycle.activate(config_value.allocation, now_ns);
        self.slots[index].entry = .{ .lifecycle = lifecycle };
        errdefer self.clearSlot(index);
        const handle = TurnAllocationRefreshHandle{ .slot = @intCast(index), .generation = self.slots[index].generation };
        try self.scheduleRefresh(timers, handle, config_value.allocation, now_ns);
        return handle;
    }

    pub fn allocation(self: *TurnAllocationRefreshScheduler, handle: TurnAllocationRefreshHandle) TurnAllocationRefreshSchedulerError!topology.TurnAllocation {
        return (try self.lookup(handle)).lifecycle.allocation orelse error.StaleRefresh;
    }

    pub fn onTimer(self: *TurnAllocationRefreshScheduler, timers: *timer_wheel.TimerWheel, timer: timer_wheel.Timer) TurnAllocationRefreshSchedulerError!?TurnAllocationRefreshEvent {
        _ = timers;
        if (timer.kind != .service) return null;
        for (self.slots, 0..) |*slot, index| {
            const entry = if (slot.entry) |*value| value else continue;
            if (entry.timer != timer.id) continue;
            entry.timer = null;
            const allocation_value = entry.lifecycle.allocation orelse return error.StaleRefresh;
            const event = try entry.lifecycle.poll(timer.deadline_ns) orelse return error.RefreshNotDue;
            return switch (event) {
                .refresh_due => .{ .refresh_due = .{ .handle = .{ .slot = @intCast(index), .generation = slot.generation }, .allocation = allocation_value } },
                else => error.RefreshNotDue,
            };
        }
        return null;
    }

    pub fn refreshed(self: *TurnAllocationRefreshScheduler, timers: *timer_wheel.TimerWheel, handle: TurnAllocationRefreshHandle, value: topology.TurnAllocation, now_ns: core.TimeNs) TurnAllocationRefreshSchedulerError!void {
        const entry = try self.lookup(handle);
        if (entry.timer != null) return error.RefreshNotDue;
        try entry.lifecycle.refreshed(value, now_ns);
        try self.scheduleRefresh(timers, handle, value, now_ns);
    }

    pub fn failed(self: *TurnAllocationRefreshScheduler, timers: *timer_wheel.TimerWheel, handle: TurnAllocationRefreshHandle, failure: topology.TurnAllocationFailure, now_ns: core.TimeNs) TurnAllocationRefreshSchedulerError!TurnAllocationRefreshEvent {
        const entry = try self.lookup(handle);
        if (entry.timer != null) return error.RefreshNotDue;
        const event = entry.lifecycle.failed(failure) catch |err| {
            if (err == error.FailureLimitReached) self.clearSlot(handle.slot);
            return err;
        };
        switch (event) {
            .recoverable_failure => {
                const retry_at_ns = now_ns +| self.config.retry_delay_ns;
                entry.timer = try timers.schedule(.service, retry_at_ns);
                return .{ .recoverable_failure = .{ .handle = handle, .failure = failure, .retry_at_ns = retry_at_ns } };
            },
            else => return error.RefreshNotDue,
        }
    }

    pub fn closeSession(self: *TurnAllocationRefreshScheduler, timers: *timer_wheel.TimerWheel, handle: TurnAllocationRefreshHandle) TurnAllocationRefreshSchedulerError!TurnAllocationRefreshEvent {
        const entry = try self.lookup(handle);
        if (entry.timer) |timer| try timers.cancel(timer);
        _ = try entry.lifecycle.deallocate();
        self.clearSlot(handle.slot);
        return .{ .released = handle };
    }

    fn scheduleRefresh(self: *TurnAllocationRefreshScheduler, timers: *timer_wheel.TimerWheel, handle: TurnAllocationRefreshHandle, allocation_value: topology.TurnAllocation, now_ns: core.TimeNs) TurnAllocationRefreshSchedulerError!void {
        const entry = try self.lookup(handle);
        const deadline_ns = @max(now_ns, allocation_value.expires_at_ns -| self.config.refresh_margin_ns);
        entry.timer = try timers.schedule(.service, deadline_ns);
    }

    fn lookup(self: *TurnAllocationRefreshScheduler, handle: TurnAllocationRefreshHandle) TurnAllocationRefreshSchedulerError!*Entry {
        if (handle.slot >= self.slots.len) return error.StaleRefresh;
        const slot = &self.slots[handle.slot];
        if (slot.generation != handle.generation) return error.StaleRefresh;
        return if (slot.entry) |*entry| entry else error.StaleRefresh;
    }

    fn freeSlot(self: *const TurnAllocationRefreshScheduler) ?usize {
        for (self.slots, 0..) |slot, index| if (slot.entry == null) return index;
        return null;
    }

    fn clearSlot(self: *TurnAllocationRefreshScheduler, index: usize) void {
        const slot = &self.slots[index];
        slot.entry = null;
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
    }
};

test "TURN allocation refresh schedulers refresh once and release on session close" {
    var timers = try timer_wheel.TimerWheel.init(std.testing.allocator, 3);
    defer timers.deinit();
    var scheduler = try TurnAllocationRefreshScheduler.init(std.testing.allocator, .{ .maximum_allocations = 2, .refresh_margin_ns = 10, .retry_delay_ns = 2, .maximum_failures = 2 });
    defer scheduler.deinit(&timers);
    const relay = topology.TurnAllocation{ .relay = .{ .ipv4 = .{ .octets = .{ 203, 0, 113, 1 }, .port = 5000 } }, .expires_at_ns = 100 };
    const handle = try scheduler.activate(&timers, .{ .allocation = relay, .credential_expires_at_ns = 200 }, 0);
    try std.testing.expect((try timers.advance(89)) == null);
    const due = (try timers.advance(90)).?;
    const event = (try scheduler.onTimer(&timers, due)).?;
    switch (event) {
        .refresh_due => |value| try std.testing.expectEqual(handle, value.handle),
        else => return error.TestUnexpectedResult,
    }
    const refreshed = topology.TurnAllocation{ .relay = relay.relay, .expires_at_ns = 180 };
    try scheduler.refreshed(&timers, handle, refreshed, 90);
    try std.testing.expectEqual(@as(core.TimeNs, 170), timers.nextDeadline().?);
    try std.testing.expectEqual(TurnAllocationRefreshEvent{ .released = handle }, try scheduler.closeSession(&timers, handle));
    try std.testing.expect((try timers.advance(180)) == null);
    try std.testing.expectError(error.StaleRefresh, scheduler.allocation(handle));
}

test "TURN allocation refresh schedulers bound retry failures and cleanup" {
    var timers = try timer_wheel.TimerWheel.init(std.testing.allocator, 3);
    defer timers.deinit();
    var scheduler = try TurnAllocationRefreshScheduler.init(std.testing.allocator, .{ .maximum_allocations = 1, .refresh_margin_ns = 5, .retry_delay_ns = 2, .maximum_failures = 2 });
    defer scheduler.deinit(&timers);
    const allocation = topology.TurnAllocation{ .relay = .{ .ipv4 = .{ .octets = .{ 1, 1, 1, 1 }, .port = 1 } }, .expires_at_ns = 20 };
    const handle = try scheduler.activate(&timers, .{ .allocation = allocation, .credential_expires_at_ns = 30 }, 0);
    const due = (try timers.advance(15)).?;
    _ = (try scheduler.onTimer(&timers, due)).?;
    const retry = try scheduler.failed(&timers, handle, .transport, 15);
    try std.testing.expectEqual(TurnAllocationRefreshEvent{ .recoverable_failure = .{ .handle = handle, .failure = .transport, .retry_at_ns = 17 } }, retry);
    const retry_due = (try timers.advance(17)).?;
    _ = (try scheduler.onTimer(&timers, retry_due)).?;
    try std.testing.expectError(error.FailureLimitReached, scheduler.failed(&timers, handle, .transport, 17));
    try std.testing.expectError(error.StaleRefresh, scheduler.closeSession(&timers, handle));
}
