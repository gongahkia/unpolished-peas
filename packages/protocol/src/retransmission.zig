const std = @import("std");
const ack_ranges = @import("ack_ranges.zig");

pub const max_retransmission_entries: usize = 64;
pub const RetransmissionError = error{ InvalidConfiguration, CapacityExceeded, DuplicateSequence, UnknownSequence, RetryLimitReached };

pub const RetransmissionConfig = struct {
    timeout_ns: u64,
    maximum_retries: u8,
};

pub const RetransmissionEntry = struct {
    sequence: u32,
    sent_at_ns: u64,
    retries: u8 = 0,
};

pub const RetransmissionPollResult = struct {
    due: usize = 0,
    retry_exhausted: usize = 0,
    backpressured: bool = false,
};

pub const RetransmissionScheduler = struct {
    config: RetransmissionConfig,
    entries: [max_retransmission_entries]?RetransmissionEntry = .{null} ** max_retransmission_entries,

    pub fn init(config: RetransmissionConfig) RetransmissionError!RetransmissionScheduler {
        if (config.timeout_ns == 0) return error.InvalidConfiguration;
        return .{ .config = config };
    }

    pub fn schedule(self: *RetransmissionScheduler, sequence: u32, now_ns: u64) RetransmissionError!void {
        for (&self.entries) |*entry| {
            if (entry.*) |existing| if (existing.sequence == sequence) return error.DuplicateSequence;
        }
        for (&self.entries) |*entry| {
            if (entry.* == null) {
                entry.* = .{ .sequence = sequence, .sent_at_ns = now_ns };
                return;
            }
        }
        return error.CapacityExceeded;
    }

    pub fn acknowledge(self: *RetransmissionScheduler, ranges: ack_ranges.AckRanges) void {
        for (&self.entries) |*entry| {
            const existing = entry.* orelse continue;
            for (ranges.ranges[0..ranges.count]) |range| if (range.contains(existing.sequence)) {
                entry.* = null;
                break;
            };
        }
    }

    pub fn collect_due(self: *RetransmissionScheduler, now_ns: u64, writable: bool, output: []u32) RetransmissionPollResult {
        if (!writable) return .{ .backpressured = true };
        var result = RetransmissionPollResult{};
        for (self.entries) |entry| {
            const existing = entry orelse continue;
            if (now_ns -| existing.sent_at_ns < self.config.timeout_ns) continue;
            if (existing.retries == self.config.maximum_retries) {
                result.retry_exhausted += 1;
                continue;
            }
            if (result.due < output.len) {
                output[result.due] = existing.sequence;
                result.due += 1;
            }
        }
        return result;
    }

    pub fn commit_retransmission(self: *RetransmissionScheduler, sequence: u32, now_ns: u64) RetransmissionError!void {
        for (&self.entries) |*entry| {
            if (entry.*) |*existing| {
                if (existing.sequence != sequence) continue;
                if (existing.retries == self.config.maximum_retries) return error.RetryLimitReached;
                existing.retries += 1;
                existing.sent_at_ns = now_ns;
                return;
            }
        }
        return error.UnknownSequence;
    }
};

test "retransmission scheduling respects timers acknowledgements and backpressure" {
    var scheduler = try RetransmissionScheduler.init(.{ .timeout_ns = 10, .maximum_retries = 2 });
    try scheduler.schedule(1, 0);
    var due: [2]u32 = undefined;
    try std.testing.expect((scheduler.collect_due(10, false, due[0..])).backpressured);
    try std.testing.expectEqual(@as(usize, 1), scheduler.collect_due(10, true, due[0..]).due);
    try std.testing.expectEqual(@as(u32, 1), due[0]);
    try scheduler.commit_retransmission(1, 10);
    var acknowledgements = ack_ranges.AckRanges{};
    try acknowledgements.insert(1);
    scheduler.acknowledge(acknowledgements);
    try std.testing.expectEqual(@as(usize, 0), scheduler.collect_due(30, true, due[0..]).due);
}

test "retransmission scheduling enforces bounded retries and capacity" {
    var scheduler = try RetransmissionScheduler.init(.{ .timeout_ns = 1, .maximum_retries = 1 });
    try scheduler.schedule(7, 0);
    try scheduler.commit_retransmission(7, 1);
    var due: [1]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 1), scheduler.collect_due(2, true, due[0..]).retry_exhausted);
    try std.testing.expectError(error.RetryLimitReached, scheduler.commit_retransmission(7, 2));
    try std.testing.expectError(error.DuplicateSequence, scheduler.schedule(7, 2));
}
