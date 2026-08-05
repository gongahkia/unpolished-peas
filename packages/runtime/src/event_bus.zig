const std = @import("std");
const event = @import("event.zig");

threadlocal var dispatching: bool = false;

pub const max_runtime_event_sinks: usize = 16;

pub const RuntimeEventDestination = enum {
    metrics,
    logging,
    callback,
    replay,
};

pub const RuntimeEventSinkFn = *const fn (?*anyopaque, *const event.EventEnvelope) void;

pub const RuntimeEventSink = struct {
    destination: RuntimeEventDestination,
    context: ?*anyopaque,
    receive: RuntimeEventSinkFn,
};

pub const RuntimeEventSubscription = struct {
    id: u64,
};

pub const RuntimeEventBusError = event.EventOrderError || error{
    InvalidConfiguration,
    SinkCapacityExceeded,
    UnknownSubscription,
    ReentrantEmit,
};

pub const RuntimeEventBusConfig = struct {
    maximum_sinks: usize = max_runtime_event_sinks,
};

const Registration = struct {
    subscription: RuntimeEventSubscription,
    sink: RuntimeEventSink,
};

pub const RuntimeEventBus = struct {
    config: RuntimeEventBusConfig,
    state_mutex: std.Thread.Mutex = .{},
    dispatch_mutex: std.Thread.Mutex = .{},
    order: event.EventOrder = .{},
    next_subscription_id: u64 = 1,
    emitted_count: u64 = 0,
    registrations: [max_runtime_event_sinks]?Registration = [_]?Registration{null} ** max_runtime_event_sinks,

    pub fn init(config: RuntimeEventBusConfig) RuntimeEventBusError!RuntimeEventBus {
        if (config.maximum_sinks == 0 or config.maximum_sinks > max_runtime_event_sinks) return error.InvalidConfiguration;
        return .{ .config = config };
    }

    pub fn register(self: *RuntimeEventBus, sink: RuntimeEventSink) RuntimeEventBusError!RuntimeEventSubscription {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        for (self.registrations[0..self.config.maximum_sinks]) |*registration| {
            if (registration.* != null) continue;
            const subscription = RuntimeEventSubscription{ .id = self.nextSubscriptionId() };
            registration.* = .{ .subscription = subscription, .sink = sink };
            return subscription;
        }
        return error.SinkCapacityExceeded;
    }

    pub fn unregister(self: *RuntimeEventBus, subscription: RuntimeEventSubscription) RuntimeEventBusError!void {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        for (self.registrations[0..self.config.maximum_sinks]) |*registration| {
            const registered = registration.* orelse continue;
            if (registered.subscription.id != subscription.id) continue;
            registration.* = null;
            return;
        }
        return error.UnknownSubscription;
    }

    pub fn emit(self: *RuntimeEventBus, envelope: *const event.EventEnvelope) RuntimeEventBusError!usize {
        if (dispatching) return error.ReentrantEmit;
        self.dispatch_mutex.lock();
        defer self.dispatch_mutex.unlock();

        var sinks: [max_runtime_event_sinks]RuntimeEventSink = undefined;
        self.state_mutex.lock();
        self.order.accept(envelope) catch |err| {
            self.state_mutex.unlock();
            return err;
        };
        var count: usize = 0;
        for (self.registrations[0..self.config.maximum_sinks]) |registration| {
            const registered = registration orelse continue;
            sinks[count] = registered.sink;
            count += 1;
        }
        self.emitted_count +%= 1;
        self.state_mutex.unlock();

        dispatching = true;
        defer dispatching = false;
        for (sinks[0..count]) |sink| sink.receive(sink.context, envelope);
        return count;
    }

    pub fn emitted(self: *RuntimeEventBus) u64 {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        return self.emitted_count;
    }

    fn nextSubscriptionId(self: *RuntimeEventBus) u64 {
        const id = self.next_subscription_id;
        self.next_subscription_id +%= 1;
        if (self.next_subscription_id == 0) self.next_subscription_id = 1;
        return id;
    }
};

test "runtime event buses route ordered SDK events to every destination" {
    const Capture = struct {
        count: usize = 0,
        sequence: u64 = 0,
        kind: ?event.EventKind = null,

        fn receive(context: ?*anyopaque, envelope: *const event.EventEnvelope) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.count += 1;
            self.sequence = envelope.sequence;
            self.kind = std.meta.activeTag(envelope.event);
        }
    };
    var bus = try RuntimeEventBus.init(.{});
    var metrics = Capture{};
    var logging = Capture{};
    var callbacks = Capture{};
    var replay = Capture{};
    _ = try bus.register(.{ .destination = .metrics, .context = &metrics, .receive = Capture.receive });
    _ = try bus.register(.{ .destination = .logging, .context = &logging, .receive = Capture.receive });
    _ = try bus.register(.{ .destination = .callback, .context = &callbacks, .receive = Capture.receive });
    _ = try bus.register(.{ .destination = .replay, .context = &replay, .receive = Capture.receive });
    const envelope = event.EventEnvelope{ .sequence = 0, .mode = .poll, .event = .{ .connected = {} } };
    try std.testing.expectEqual(@as(usize, 4), try bus.emit(&envelope));
    try std.testing.expectEqual(@as(u64, 1), bus.emitted());
    inline for ([_]*const Capture{ &metrics, &logging, &callbacks, &replay }) |capture| {
        try std.testing.expectEqual(@as(usize, 1), capture.count);
        try std.testing.expectEqual(@as(u64, 0), capture.sequence);
        try std.testing.expectEqual(event.EventKind.connected, capture.kind.?);
    }
}

test "runtime event buses bound registrations and reject invalid delivery" {
    const receive = struct {
        fn callback(_: ?*anyopaque, _: *const event.EventEnvelope) void {}
    }.callback;
    try std.testing.expectError(error.InvalidConfiguration, RuntimeEventBus.init(.{ .maximum_sinks = 0 }));
    try std.testing.expectError(error.InvalidConfiguration, RuntimeEventBus.init(.{ .maximum_sinks = max_runtime_event_sinks + 1 }));
    var bus = try RuntimeEventBus.init(.{ .maximum_sinks = 1 });
    const subscription = try bus.register(.{ .destination = .callback, .context = null, .receive = receive });
    try std.testing.expectError(error.SinkCapacityExceeded, bus.register(.{ .destination = .replay, .context = null, .receive = receive }));
    try std.testing.expectError(error.UnknownSubscription, bus.unregister(.{ .id = subscription.id + 1 }));
    try bus.unregister(subscription);
    const out_of_order = event.EventEnvelope{ .sequence = 1, .mode = .poll, .event = .{ .disconnected = {} } };
    try std.testing.expectError(error.OutOfOrderEvent, bus.emit(&out_of_order));
}

test "runtime event buses reject callback reentry" {
    const Fixture = struct {
        bus: ?*RuntimeEventBus = null,
        result: ?RuntimeEventBusError = null,

        fn receive(context: ?*anyopaque, _: *const event.EventEnvelope) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            const nested = event.EventEnvelope{ .sequence = 1, .mode = .poll, .event = .{ .connected = {} } };
            _ = self.bus.?.emit(&nested) catch |err| {
                self.result = err;
            };
        }
    };
    var bus = try RuntimeEventBus.init(.{});
    var fixture = Fixture{ .bus = &bus };
    _ = try bus.register(.{ .destination = .callback, .context = &fixture, .receive = Fixture.receive });
    const initial = event.EventEnvelope{ .sequence = 0, .mode = .poll, .event = .{ .connected = {} } };
    _ = try bus.emit(&initial);
    try std.testing.expectEqual(error.ReentrantEmit, fixture.result.?);
}
