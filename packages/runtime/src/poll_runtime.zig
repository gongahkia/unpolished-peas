const std = @import("std");
const event = @import("event.zig");
const config = @import("sdk_config.zig");

pub const PollRuntimeError = std.mem.Allocator.Error || event.EventOrderError;

pub const PollRuntime = struct {
    allocator: std.mem.Allocator,
    sdk: config.Sdk,
    events: std.ArrayListUnmanaged(event.EventEnvelope) = .empty,
    order: event.EventOrder = .{},
    polls: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, sdk: config.Sdk) PollRuntime {
        return .{ .allocator = allocator, .sdk = sdk };
    }

    pub fn deinit(self: *PollRuntime) void {
        for (self.events.items) |*queued_event| queued_event.deinit();
        self.events.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn enqueue(self: *PollRuntime, envelope: event.EventEnvelope) std.mem.Allocator.Error!void {
        try self.events.append(self.allocator, envelope);
    }

    pub fn poll(self: *PollRuntime) PollRuntimeError!?event.EventEnvelope {
        self.polls +%= 1;
        if (self.events.items.len == 0) return null;
        try self.order.accept(&self.events.items[0]);
        const next = self.events.items[0];
        for (self.events.items[1..], 0..) |queued_event, index| self.events.items[index] = queued_event;
        self.events.items.len -= 1;
        return next;
    }

    pub fn poll_count(self: *const PollRuntime) u64 {
        return self.polls;
    }
};

test "poll runtimes advance only through nonblocking caller polls" {
    var manual = @import("minna-san-core").ManualClock.init(0);
    const sdk = try config.SdkConfigBuilder.init().with_clock(manual.clock()).build();
    var runtime = PollRuntime.init(std.testing.allocator, sdk);
    defer runtime.deinit();
    try std.testing.expect((try runtime.poll()) == null);
    try std.testing.expectEqual(@as(u64, 1), runtime.poll_count());
    try runtime.enqueue(.{ .sequence = 0, .mode = .poll, .event = .{ .connected = {} } });
    var event_envelope = (try runtime.poll()).?;
    defer event_envelope.deinit();
    try std.testing.expectEqual(@as(u64, 2), runtime.poll_count());
}

test "poll runtimes preserve event ordering failures for callers" {
    var manual = @import("minna-san-core").ManualClock.init(0);
    const sdk = try config.SdkConfigBuilder.init().with_clock(manual.clock()).build();
    var runtime = PollRuntime.init(std.testing.allocator, sdk);
    defer runtime.deinit();
    try runtime.enqueue(.{ .sequence = 1, .mode = .poll, .event = .{ .disconnected = {} } });
    try std.testing.expectError(error.OutOfOrderEvent, runtime.poll());
}
