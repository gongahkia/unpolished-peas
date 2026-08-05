const std = @import("std");
const event = @import("event.zig");
const event_bus = @import("event_bus.zig");

threadlocal var dispatching: bool = false;

pub const max_runtime_log_callbacks: usize = 16;

pub const RuntimeLogLevel = enum {
    trace,
    debug,
    info,
    warning,
    err,
};

pub const RuntimeLogCategory = enum {
    runtime,
    connection,
    message,
    queue,
    security,
    replay,
};

pub const RuntimeLogRedaction = enum {
    none,
    payload,
    metadata,
    all,
};

pub const RuntimeLogInput = struct {
    level: RuntimeLogLevel,
    category: RuntimeLogCategory,
    redaction: RuntimeLogRedaction,
    message: []const u8,
    source_event_sequence: ?u64 = null,
};

pub const RuntimeLogRecord = struct {
    sequence: u64,
    level: RuntimeLogLevel,
    category: RuntimeLogCategory,
    redaction: RuntimeLogRedaction,
    message: []const u8,
    source_event_sequence: ?u64,
};

pub const RuntimeLogCallback = *const fn (?*anyopaque, *const RuntimeLogRecord) void;

pub const RuntimeLogSink = struct {
    context: ?*anyopaque,
    receive: RuntimeLogCallback,
};

pub const RuntimeLogSubscription = struct {
    id: u64,
};

pub const RuntimeLoggerError = error{
    InvalidConfiguration,
    CallbackCapacityExceeded,
    UnknownSubscription,
    ReentrantEmit,
};

pub const RuntimeLoggerConfig = struct {
    maximum_callbacks: usize = max_runtime_log_callbacks,
};

const Registration = struct {
    subscription: RuntimeLogSubscription,
    sink: RuntimeLogSink,
};

pub const RuntimeLogger = struct {
    config: RuntimeLoggerConfig,
    state_mutex: std.Thread.Mutex = .{},
    dispatch_mutex: std.Thread.Mutex = .{},
    next_subscription_id: u64 = 1,
    next_record_sequence: u64 = 0,
    emitted_count: u64 = 0,
    registrations: [max_runtime_log_callbacks]?Registration = [_]?Registration{null} ** max_runtime_log_callbacks,

    pub fn init(config: RuntimeLoggerConfig) RuntimeLoggerError!RuntimeLogger {
        if (config.maximum_callbacks == 0 or config.maximum_callbacks > max_runtime_log_callbacks) return error.InvalidConfiguration;
        return .{ .config = config };
    }

    pub fn register(self: *RuntimeLogger, callback_sink: RuntimeLogSink) RuntimeLoggerError!RuntimeLogSubscription {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        for (self.registrations[0..self.config.maximum_callbacks]) |*registration| {
            if (registration.* != null) continue;
            const subscription = RuntimeLogSubscription{ .id = self.nextSubscriptionId() };
            registration.* = .{ .subscription = subscription, .sink = callback_sink };
            return subscription;
        }
        return error.CallbackCapacityExceeded;
    }

    pub fn unregister(self: *RuntimeLogger, subscription: RuntimeLogSubscription) RuntimeLoggerError!void {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        for (self.registrations[0..self.config.maximum_callbacks]) |*registration| {
            const registered = registration.* orelse continue;
            if (registered.subscription.id != subscription.id) continue;
            registration.* = null;
            return;
        }
        return error.UnknownSubscription;
    }

    pub fn emit(self: *RuntimeLogger, input: RuntimeLogInput) RuntimeLoggerError!usize {
        if (dispatching) return error.ReentrantEmit;
        self.dispatch_mutex.lock();
        defer self.dispatch_mutex.unlock();

        var sinks: [max_runtime_log_callbacks]RuntimeLogSink = undefined;
        self.state_mutex.lock();
        var count: usize = 0;
        for (self.registrations[0..self.config.maximum_callbacks]) |registration| {
            const registered = registration orelse continue;
            sinks[count] = registered.sink;
            count += 1;
        }
        const record = RuntimeLogRecord{
            .sequence = self.next_record_sequence,
            .level = input.level,
            .category = input.category,
            .redaction = input.redaction,
            .message = sanitized_message(input),
            .source_event_sequence = input.source_event_sequence,
        };
        self.next_record_sequence +%= 1;
        self.emitted_count +%= 1;
        self.state_mutex.unlock();

        dispatching = true;
        defer dispatching = false;
        for (sinks[0..count]) |callback_sink| callback_sink.receive(callback_sink.context, &record);
        return count;
    }

    pub fn sink(self: *RuntimeLogger) event_bus.RuntimeEventSink {
        return .{ .destination = .logging, .context = self, .receive = observe_event };
    }

    pub fn attach(self: *RuntimeLogger, bus: *event_bus.RuntimeEventBus) event_bus.RuntimeEventBusError!event_bus.RuntimeEventSubscription {
        return bus.register(self.sink());
    }

    pub fn emitted(self: *RuntimeLogger) u64 {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        return self.emitted_count;
    }

    fn nextSubscriptionId(self: *RuntimeLogger) u64 {
        const id = self.next_subscription_id;
        self.next_subscription_id +%= 1;
        if (self.next_subscription_id == 0) self.next_subscription_id = 1;
        return id;
    }

    fn observe_event(context: ?*anyopaque, envelope: *const event.EventEnvelope) void {
        const self: *RuntimeLogger = @ptrCast(@alignCast(context.?));
        const input: RuntimeLogInput = switch (envelope.event) {
            .connected => .{ .level = .info, .category = .connection, .redaction = .none, .message = "connected", .source_event_sequence = envelope.sequence },
            .disconnected => .{ .level = .info, .category = .connection, .redaction = .none, .message = "disconnected", .source_event_sequence = envelope.sequence },
            .message => .{ .level = .debug, .category = .message, .redaction = .payload, .message = "", .source_event_sequence = envelope.sequence },
            .overflow => .{ .level = .warning, .category = .queue, .redaction = .none, .message = "event overflow", .source_event_sequence = envelope.sequence },
        };
        _ = self.emit(input) catch {};
    }
};

fn sanitized_message(input: RuntimeLogInput) []const u8 {
    return switch (input.redaction) {
        .none => input.message,
        .payload => "[payload redacted]",
        .metadata => "[metadata redacted]",
        .all => "[redacted]",
    };
}

test "runtime loggers emit structured redacted records through consumer callbacks" {
    const Capture = struct {
        calls: usize = 0,
        record: ?RuntimeLogRecord = null,

        fn receive(context: ?*anyopaque, record: *const RuntimeLogRecord) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            self.record = record.*;
        }
    };
    var logger = try RuntimeLogger.init(.{});
    var capture = Capture{};
    _ = try logger.register(.{ .context = &capture, .receive = Capture.receive });
    try std.testing.expectEqual(@as(usize, 1), try logger.emit(.{ .level = .warning, .category = .security, .redaction = .payload, .message = "secret" }));
    const record = capture.record.?;
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(@as(u64, 0), record.sequence);
    try std.testing.expectEqual(RuntimeLogLevel.warning, record.level);
    try std.testing.expectEqual(RuntimeLogCategory.security, record.category);
    try std.testing.expectEqual(RuntimeLogRedaction.payload, record.redaction);
    try std.testing.expectEqualStrings("[payload redacted]", record.message);
    try std.testing.expect(record.source_event_sequence == null);
}

test "runtime loggers consume bus events without exposing payload bytes" {
    const Capture = struct {
        record: ?RuntimeLogRecord = null,

        fn receive(context: ?*anyopaque, record: *const RuntimeLogRecord) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.record = record.*;
        }
    };
    var bus = try event_bus.RuntimeEventBus.init(.{});
    var logger = try RuntimeLogger.init(.{});
    var capture = Capture{};
    _ = try logger.register(.{ .context = &capture, .receive = Capture.receive });
    _ = try logger.attach(&bus);
    const envelope = event.EventEnvelope{ .sequence = 0, .mode = .poll, .event = .{ .message = .{ .buffer = .{ .borrowed = .init("secret") } } } };
    _ = try bus.emit(&envelope);
    const record = capture.record.?;
    try std.testing.expectEqual(RuntimeLogLevel.debug, record.level);
    try std.testing.expectEqual(RuntimeLogCategory.message, record.category);
    try std.testing.expectEqual(RuntimeLogRedaction.payload, record.redaction);
    try std.testing.expectEqualStrings("[payload redacted]", record.message);
    try std.testing.expectEqual(@as(?u64, 0), record.source_event_sequence);
}

test "runtime loggers have no default exporter and reject invalid registration or reentry" {
    const Reentrant = struct {
        logger: ?*RuntimeLogger = null,
        result: ?RuntimeLoggerError = null,

        fn receive(context: ?*anyopaque, _: *const RuntimeLogRecord) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            _ = self.logger.?.emit(.{ .level = .info, .category = .runtime, .redaction = .none, .message = "nested" }) catch |err| {
                self.result = err;
            };
        }
    };
    try std.testing.expectError(error.InvalidConfiguration, RuntimeLogger.init(.{ .maximum_callbacks = 0 }));
    try std.testing.expectError(error.InvalidConfiguration, RuntimeLogger.init(.{ .maximum_callbacks = max_runtime_log_callbacks + 1 }));
    var logger = try RuntimeLogger.init(.{ .maximum_callbacks = 1 });
    try std.testing.expectEqual(@as(usize, 0), try logger.emit(.{ .level = .info, .category = .runtime, .redaction = .none, .message = "not exported" }));
    var reentrant = Reentrant{ .logger = &logger };
    const subscription = try logger.register(.{ .context = &reentrant, .receive = Reentrant.receive });
    try std.testing.expectError(error.CallbackCapacityExceeded, logger.register(.{ .context = null, .receive = Reentrant.receive }));
    try std.testing.expectError(error.UnknownSubscription, logger.unregister(.{ .id = subscription.id + 1 }));
    _ = try logger.emit(.{ .level = .info, .category = .runtime, .redaction = .none, .message = "outer" });
    try std.testing.expectEqual(error.ReentrantEmit, reentrant.result.?);
}
