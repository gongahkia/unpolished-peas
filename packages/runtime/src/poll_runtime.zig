const std = @import("std");
const core = @import("minna-san-core");
const event = @import("event.zig");
const config = @import("sdk_config.zig");

pub const PollRuntimeError = std.mem.Allocator.Error || event.EventOrderError || error{ InvalidPollInput, ReentrantPoll };

pub const PollInput = struct {
    now_ns: core.TimeNs,
    work_budget: usize = 1,
    deadline_ns: ?core.TimeNs = null,

    pub fn validate(self: PollInput) PollRuntimeError!void {
        if (self.work_budget == 0) return error.InvalidPollInput;
    }
};

pub const PollProgress = enum {
    idle,
    provider,
    event,
    deadline,
};

pub const PollOutcome = struct {
    progress: PollProgress = .idle,
    work_completed: usize = 0,
    next_deadline: ?core.TimeNs = null,
    event: ?event.EventEnvelope = null,

    pub fn deinit(self: *PollOutcome) void {
        if (self.event) |*envelope| envelope.deinit();
        self.* = undefined;
    }
};

pub const PollRuntime = struct {
    allocator: std.mem.Allocator,
    sdk: config.Sdk,
    events: std.ArrayListUnmanaged(event.EventEnvelope) = .empty,
    order: event.EventOrder = .{},
    polls: u64 = 0,
    poll_active: bool = false,

    pub fn init(allocator: std.mem.Allocator, sdk: config.Sdk) PollRuntime {
        return .{ .allocator = allocator, .sdk = sdk };
    }

    pub fn deinit(self: *PollRuntime) void {
        for (self.events.items) |*queued_event| queued_event.deinit();
        self.events.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn enqueue(self: *PollRuntime, envelope: event.EventEnvelope) std.mem.Allocator.Error!void {
        const capacity = self.sdk.configuration().platformConfig().limits.event_capacity;
        if (self.events.items.len < capacity) return self.events.append(self.allocator, envelope);
        self.enqueueOverflow(envelope);
    }

    pub fn poll(self: *PollRuntime, input: PollInput) PollRuntimeError!PollOutcome {
        try input.validate();
        if (self.poll_active) return error.ReentrantPoll;
        self.poll_active = true;
        defer self.poll_active = false;
        self.polls +%= 1;
        if (input.deadline_ns) |deadline| {
            if (input.now_ns >= deadline) return .{ .progress = .deadline, .next_deadline = deadline };
        }
        if (self.events.items.len == 0) return .{ .next_deadline = input.deadline_ns };
        try self.order.accept(&self.events.items[0]);
        const next = self.events.items[0];
        for (self.events.items[1..], 0..) |queued_event, index| self.events.items[index] = queued_event;
        self.events.items.len -= 1;
        return .{ .progress = .event, .work_completed = 1, .next_deadline = input.deadline_ns, .event = next };
    }

    pub fn poll_count(self: *const PollRuntime) u64 {
        return self.polls;
    }

    fn enqueueOverflow(self: *PollRuntime, envelope: event.EventEnvelope) void {
        if (self.events.items[0].event == .overflow) {
            if (self.events.items.len == 1) {
                var dropped = envelope;
                dropped.deinit();
            } else {
                self.events.items[1].deinit();
                for (self.events.items[2..], 1..) |queued_event, index| self.events.items[index] = queued_event;
                self.events.items[self.events.items.len - 1] = envelope;
            }
            self.events.items[0].event.overflow.dropped_count +%= 1;
            return;
        }
        const first_sequence = self.events.items[0].sequence;
        const first_mode = self.events.items[0].mode;
        self.events.items[0].deinit();
        if (self.events.items.len == 1) {
            var dropped = envelope;
            dropped.deinit();
            self.events.items[0] = .{ .sequence = first_sequence, .mode = first_mode, .event = .{ .overflow = .{ .dropped_count = 2 } } };
            return;
        }
        self.events.items[1].deinit();
        for (self.events.items[2..], 1..) |queued_event, index| self.events.items[index] = queued_event;
        self.events.items[0] = .{ .sequence = first_sequence, .mode = first_mode, .event = .{ .overflow = .{ .dropped_count = 2 } } };
        self.events.items[self.events.items.len - 1] = envelope;
    }
};

test "poll runtimes advance only through nonblocking caller polls" {
    var manual = core.ManualClock.init(0);
    const sdk = try config.SdkConfigBuilder.init().with_clock(manual.clock()).build();
    var runtime = PollRuntime.init(std.testing.allocator, sdk);
    defer runtime.deinit();
    var idle = try runtime.poll(.{ .now_ns = manual.clock().now() });
    defer idle.deinit();
    try std.testing.expectEqual(PollProgress.idle, idle.progress);
    try std.testing.expectEqual(@as(u64, 1), runtime.poll_count());
    try runtime.enqueue(.{ .sequence = 0, .mode = .poll, .event = .{ .connected = {} } });
    var outcome = try runtime.poll(.{ .now_ns = manual.clock().now() });
    defer outcome.deinit();
    try std.testing.expectEqual(PollProgress.event, outcome.progress);
    try std.testing.expect(outcome.event != null);
    try std.testing.expectEqual(@as(u64, 2), runtime.poll_count());
}

test "poll runtimes preserve event ordering failures for callers" {
    var manual = core.ManualClock.init(0);
    const sdk = try config.SdkConfigBuilder.init().with_clock(manual.clock()).build();
    var runtime = PollRuntime.init(std.testing.allocator, sdk);
    defer runtime.deinit();
    try runtime.enqueue(.{ .sequence = 1, .mode = .poll, .event = .{ .disconnected = {} } });
    try std.testing.expectError(error.OutOfOrderEvent, runtime.poll(.{ .now_ns = manual.clock().now() }));
}

test "poll runtimes bound queued events and coalesce ordered overflow" {
    var manual = core.ManualClock.init(0);
    const sdk = try config.SdkConfigBuilder.init().with_clock(manual.clock()).with_platform_config(.{ .limits = .{ .provider_capacity = 1, .service_capacity = 0, .session_capacity = 1, .channel_capacity = 1, .event_capacity = 2, .poll_work_budget = 1 } }).build();
    var runtime = PollRuntime.init(std.testing.allocator, sdk);
    defer runtime.deinit();
    try runtime.enqueue(.{ .sequence = 0, .mode = .poll, .event = .{ .connected = {} } });
    try runtime.enqueue(.{ .sequence = 1, .mode = .poll, .event = .{ .disconnected = {} } });
    try runtime.enqueue(.{ .sequence = 2, .mode = .poll, .event = .{ .connected = {} } });
    try runtime.enqueue(.{ .sequence = 3, .mode = .poll, .event = .{ .disconnected = {} } });
    try std.testing.expectEqual(@as(usize, 2), runtime.events.items.len);
    var overflow = try runtime.poll(.{ .now_ns = manual.clock().now() });
    defer overflow.deinit();
    try std.testing.expectEqual(PollProgress.event, overflow.progress);
    try std.testing.expectEqual(@as(u64, 0), overflow.event.?.sequence);
    switch (overflow.event.?.event) {
        .overflow => |value| try std.testing.expectEqual(@as(u64, 3), value.dropped_count),
        else => return error.TestExpectedEqual,
    }
    var retained = try runtime.poll(.{ .now_ns = manual.clock().now() });
    defer retained.deinit();
    try std.testing.expectEqual(@as(u64, 3), retained.event.?.sequence);
    try std.testing.expect(retained.event.?.event == .disconnected);
}

test "single-slot poll runtimes retain an overflow summary" {
    var manual = core.ManualClock.init(0);
    const sdk = try config.SdkConfigBuilder.init().with_clock(manual.clock()).with_platform_config(.{ .limits = .{ .provider_capacity = 1, .service_capacity = 0, .session_capacity = 1, .channel_capacity = 1, .event_capacity = 1, .poll_work_budget = 1 } }).build();
    var runtime = PollRuntime.init(std.testing.allocator, sdk);
    defer runtime.deinit();
    try runtime.enqueue(.{ .sequence = 0, .mode = .poll, .event = .{ .connected = {} } });
    try runtime.enqueue(.{ .sequence = 1, .mode = .poll, .event = .{ .disconnected = {} } });
    try runtime.enqueue(.{ .sequence = 2, .mode = .poll, .event = .{ .connected = {} } });
    try std.testing.expectEqual(@as(usize, 1), runtime.events.items.len);
    var overflow = try runtime.poll(.{ .now_ns = manual.clock().now() });
    defer overflow.deinit();
    switch (overflow.event.?.event) {
        .overflow => |value| try std.testing.expectEqual(@as(u64, 3), value.dropped_count),
        else => return error.TestExpectedEqual,
    }
}

test "poll runtimes make deterministic deadline and reentrancy outcomes explicit" {
    var first_clock = core.ManualClock.init(10);
    var second_clock = core.ManualClock.init(10);
    const first_sdk = try config.SdkConfigBuilder.init().with_clock(first_clock.clock()).build();
    const second_sdk = try config.SdkConfigBuilder.init().with_clock(second_clock.clock()).build();
    var first = PollRuntime.init(std.testing.allocator, first_sdk);
    defer first.deinit();
    var second = PollRuntime.init(std.testing.allocator, second_sdk);
    defer second.deinit();
    try first.enqueue(.{ .sequence = 0, .mode = .poll, .event = .{ .connected = {} } });
    try second.enqueue(.{ .sequence = 0, .mode = .poll, .event = .{ .connected = {} } });
    var first_outcome = try first.poll(.{ .now_ns = first_clock.clock().now(), .deadline_ns = 11 });
    defer first_outcome.deinit();
    var second_outcome = try second.poll(.{ .now_ns = second_clock.clock().now(), .deadline_ns = 11 });
    defer second_outcome.deinit();
    try std.testing.expectEqual(first_outcome.progress, second_outcome.progress);
    try std.testing.expectEqual(first_outcome.work_completed, second_outcome.work_completed);
    try std.testing.expectEqual(first_outcome.next_deadline, second_outcome.next_deadline);
    try std.testing.expect(first_outcome.event != null);
    try std.testing.expect(second_outcome.event != null);
    try std.testing.expectEqual(first.poll_count(), second.poll_count());
    try first_clock.advance(1);
    var deadline = try first.poll(.{ .now_ns = first_clock.clock().now(), .deadline_ns = 11 });
    defer deadline.deinit();
    try std.testing.expectEqual(PollProgress.deadline, deadline.progress);
    first.poll_active = true;
    defer first.poll_active = false;
    try std.testing.expectError(error.ReentrantPoll, first.poll(.{ .now_ns = first_clock.clock().now() }));
}
