const std = @import("std");

pub const max_runtime_security_failure_events: usize = 64;

pub const RuntimeSecurityFailureClass = enum {
    authentication,
    decryption,
    replay,
    policy,
    rotation,
};

pub const runtime_security_failure_class_count = @typeInfo(RuntimeSecurityFailureClass).@"enum".fields.len;

pub const RuntimeSecurityFailureEvent = struct {
    sequence: u64,
    failure: RuntimeSecurityFailureClass,
};

pub const RuntimeSecurityFailureCounters = struct {
    failures: [runtime_security_failure_class_count]u64 = [_]u64{0} ** runtime_security_failure_class_count,
    dropped_events: u64 = 0,
};

pub const RuntimeSecurityFailureEventRegistryError = error{InvalidConfiguration};

pub const RuntimeSecurityFailureEventRegistry = struct {
    capacity: usize,
    events: [max_runtime_security_failure_events]RuntimeSecurityFailureEvent = undefined,
    event_count: usize = 0,
    next_sequence: u64 = 0,
    counters_value: RuntimeSecurityFailureCounters = .{},

    pub fn init(capacity: usize) RuntimeSecurityFailureEventRegistryError!RuntimeSecurityFailureEventRegistry {
        if (capacity == 0 or capacity > max_runtime_security_failure_events) return error.InvalidConfiguration;
        return .{ .capacity = capacity };
    }

    pub fn record(self: *RuntimeSecurityFailureEventRegistry, failure: RuntimeSecurityFailureClass) void {
        self.counters_value.failures[@intFromEnum(failure)] +%= 1;
        if (self.event_count == self.capacity) {
            self.counters_value.dropped_events +%= 1;
            return;
        }
        self.events[self.event_count] = .{ .sequence = self.next_sequence, .failure = failure };
        self.event_count += 1;
        self.next_sequence +%= 1;
    }

    pub fn poll(self: *RuntimeSecurityFailureEventRegistry) ?RuntimeSecurityFailureEvent {
        if (self.event_count == 0) return null;
        const result = self.events[0];
        for (self.events[1..self.event_count], 0..) |value, index| self.events[index] = value;
        self.event_count -= 1;
        return result;
    }

    pub fn counters(self: *const RuntimeSecurityFailureEventRegistry) RuntimeSecurityFailureCounters {
        return self.counters_value;
    }
};

test "security failure events expose only bounded failure classes and counters" {
    var events = try RuntimeSecurityFailureEventRegistry.init(2);
    events.record(.authentication);
    events.record(.replay);
    events.record(.rotation);
    try std.testing.expectEqual(RuntimeSecurityFailureEvent{ .sequence = 0, .failure = .authentication }, events.poll().?);
    try std.testing.expectEqual(RuntimeSecurityFailureEvent{ .sequence = 1, .failure = .replay }, events.poll().?);
    try std.testing.expect(events.poll() == null);
    const counters = events.counters();
    try std.testing.expectEqual(@as(u64, 1), counters.failures[@intFromEnum(RuntimeSecurityFailureClass.authentication)]);
    try std.testing.expectEqual(@as(u64, 1), counters.failures[@intFromEnum(RuntimeSecurityFailureClass.replay)]);
    try std.testing.expectEqual(@as(u64, 1), counters.failures[@intFromEnum(RuntimeSecurityFailureClass.rotation)]);
    try std.testing.expectEqual(@as(u64, 1), counters.dropped_events);
    try std.testing.expectError(error.InvalidConfiguration, RuntimeSecurityFailureEventRegistry.init(0));
}
