const std = @import("std");
const topology = @import("minna-san-topology");
const event = @import("event.zig");
const event_bus = @import("event_bus.zig");

pub const runtime_metric_histogram_upper_bounds = [_]u64{ 64, 256, 1024, 4096, 16384, 65536, 262144 };
pub const max_runtime_metric_histogram_buckets = runtime_metric_histogram_upper_bounds.len + 1;

pub const RuntimeMetricHistogram = struct {
    samples: u64 = 0,
    total: u64 = 0,
    maximum: u64 = 0,
    buckets: [max_runtime_metric_histogram_buckets]u64 = [_]u64{0} ** max_runtime_metric_histogram_buckets,

    pub fn observe(self: *RuntimeMetricHistogram, value: u64) void {
        self.samples +%= 1;
        self.total +%= value;
        self.maximum = @max(self.maximum, value);
        for (runtime_metric_histogram_upper_bounds, 0..) |upper_bound, index| {
            if (value <= upper_bound) {
                self.buckets[index] +%= 1;
                return;
            }
        }
        self.buckets[max_runtime_metric_histogram_buckets - 1] +%= 1;
    }
};

pub const RuntimeRouteHealth = struct {
    direct: topology.ShardHealth = .unavailable,
    relay: topology.ShardHealth = .unavailable,
    authoritative: topology.ShardHealth = .unavailable,
};

pub const RuntimeQueuePressure = struct {
    depth: usize,
    capacity: usize,
};

pub const RuntimeSecurityEvent = enum {
    authentication_failed,
    packet_rejected,
    replay_rejected,
    key_rotated,
};

pub const runtime_security_event_count = @typeInfo(RuntimeSecurityEvent).@"enum".fields.len;

pub const RuntimeMetricsSnapshot = struct {
    events: u64 = 0,
    connected: u64 = 0,
    disconnected: u64 = 0,
    messages: u64 = 0,
    overflows: u64 = 0,
    dropped_events: u64 = 0,
    active_connections: usize = 0,
    message_bytes: RuntimeMetricHistogram = .{},
    route_health: RuntimeRouteHealth = .{},
    queue_pressure: RuntimeQueuePressure = .{ .depth = 0, .capacity = 0 },
    security_events: [runtime_security_event_count]u64 = [_]u64{0} ** runtime_security_event_count,
};

pub const RuntimeMetricsError = error{InvalidQueuePressure};

pub const RuntimeMetrics = struct {
    mutex: std.Thread.Mutex = .{},
    snapshot_value: RuntimeMetricsSnapshot = .{},

    pub fn init() RuntimeMetrics {
        return .{};
    }

    pub fn sink(self: *RuntimeMetrics) event_bus.RuntimeEventSink {
        return .{ .destination = .metrics, .context = self, .receive = observe_event };
    }

    pub fn attach(self: *RuntimeMetrics, bus: *event_bus.RuntimeEventBus) event_bus.RuntimeEventBusError!event_bus.RuntimeEventSubscription {
        return bus.register(self.sink());
    }

    pub fn record_route_health(self: *RuntimeMetrics, kind: topology.ShardRouteKind, health: topology.ShardHealth) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        switch (kind) {
            .direct => self.snapshot_value.route_health.direct = health,
            .relay => self.snapshot_value.route_health.relay = health,
            .authoritative => self.snapshot_value.route_health.authoritative = health,
        }
    }

    pub fn record_queue_pressure(self: *RuntimeMetrics, pressure: RuntimeQueuePressure) RuntimeMetricsError!void {
        if (pressure.capacity == 0 or pressure.depth > pressure.capacity) return error.InvalidQueuePressure;
        self.mutex.lock();
        defer self.mutex.unlock();
        self.snapshot_value.queue_pressure = pressure;
    }

    pub fn record_security_event(self: *RuntimeMetrics, security_event: RuntimeSecurityEvent) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.snapshot_value.security_events[@intFromEnum(security_event)] +%= 1;
    }

    pub fn snapshot(self: *RuntimeMetrics) RuntimeMetricsSnapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.snapshot_value;
    }

    fn observe_event(context: ?*anyopaque, envelope: *const event.EventEnvelope) void {
        const self: *RuntimeMetrics = @ptrCast(@alignCast(context.?));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.snapshot_value.events +%= 1;
        switch (envelope.event) {
            .connected => {
                self.snapshot_value.connected +%= 1;
                self.snapshot_value.active_connections +%= 1;
            },
            .disconnected => {
                self.snapshot_value.disconnected +%= 1;
                self.snapshot_value.active_connections -|= 1;
            },
            .message => |message| {
                self.snapshot_value.messages +%= 1;
                self.snapshot_value.message_bytes.observe(message_len(message));
            },
            .overflow => |overflow| {
                self.snapshot_value.overflows +%= 1;
                self.snapshot_value.dropped_events +%= overflow.dropped_count;
            },
        }
    }
};

fn message_len(message: event.MessageEvent) u64 {
    const length = switch (message.buffer) {
        .borrowed => |buffer| buffer.bytes.len,
        .retained => |buffer| buffer.borrow().bytes.len,
        .transferred => |transfer| if (transfer.buffer) |buffer| buffer.bytes.len else 0,
    };
    return @intCast(length);
}

test "runtime metrics collect bounded event counters gauges and histograms" {
    var bus = try event_bus.RuntimeEventBus.init(.{});
    var metrics = RuntimeMetrics.init();
    _ = try metrics.attach(&bus);
    const connected = event.EventEnvelope{ .sequence = 0, .mode = .poll, .event = .{ .connected = {} } };
    const message = event.EventEnvelope{ .sequence = 1, .mode = .poll, .event = .{ .message = .{ .buffer = .{ .borrowed = .init("metric") } } } };
    const overflow = event.EventEnvelope{ .sequence = 2, .mode = .poll, .event = .{ .overflow = .{ .dropped_count = 3 } } };
    const disconnected = event.EventEnvelope{ .sequence = 3, .mode = .poll, .event = .{ .disconnected = {} } };
    _ = try bus.emit(&connected);
    _ = try bus.emit(&message);
    _ = try bus.emit(&overflow);
    _ = try bus.emit(&disconnected);
    const snapshot_value = metrics.snapshot();
    try std.testing.expectEqual(@as(u64, 4), snapshot_value.events);
    try std.testing.expectEqual(@as(u64, 1), snapshot_value.connected);
    try std.testing.expectEqual(@as(u64, 1), snapshot_value.disconnected);
    try std.testing.expectEqual(@as(u64, 1), snapshot_value.messages);
    try std.testing.expectEqual(@as(u64, 1), snapshot_value.overflows);
    try std.testing.expectEqual(@as(u64, 3), snapshot_value.dropped_events);
    try std.testing.expectEqual(@as(usize, 0), snapshot_value.active_connections);
    try std.testing.expectEqual(@as(u64, 1), snapshot_value.message_bytes.samples);
    try std.testing.expectEqual(@as(u64, 6), snapshot_value.message_bytes.total);
    try std.testing.expectEqual(@as(u64, 6), snapshot_value.message_bytes.maximum);
    try std.testing.expectEqual(@as(u64, 1), snapshot_value.message_bytes.buckets[0]);
}

test "runtime metrics expose bounded queue route and security state" {
    var metrics = RuntimeMetrics.init();
    try metrics.record_queue_pressure(.{ .depth = 2, .capacity = 8 });
    metrics.record_route_health(.direct, .healthy);
    metrics.record_route_health(.relay, .degraded);
    metrics.record_security_event(.replay_rejected);
    metrics.record_security_event(.replay_rejected);
    const snapshot_value = metrics.snapshot();
    try std.testing.expectEqual(RuntimeQueuePressure{ .depth = 2, .capacity = 8 }, snapshot_value.queue_pressure);
    try std.testing.expectEqual(topology.ShardHealth.healthy, snapshot_value.route_health.direct);
    try std.testing.expectEqual(topology.ShardHealth.degraded, snapshot_value.route_health.relay);
    try std.testing.expectEqual(@as(u64, 2), snapshot_value.security_events[@intFromEnum(RuntimeSecurityEvent.replay_rejected)]);
    try std.testing.expectError(error.InvalidQueuePressure, metrics.record_queue_pressure(.{ .depth = 1, .capacity = 0 }));
    try std.testing.expectError(error.InvalidQueuePressure, metrics.record_queue_pressure(.{ .depth = 9, .capacity = 8 }));
    try std.testing.expectEqual(RuntimeQueuePressure{ .depth = 2, .capacity = 8 }, metrics.snapshot().queue_pressure);
}
