const std = @import("std");

pub const max_reliable_ordered_window: usize = 64;
pub const ReliableOrderedError = error{ InvalidConfiguration, StorageTooSmall };

pub const ReliableReceiveResult = enum {
    accepted,
    duplicate,
    out_of_window,
    payload_too_large,
};

pub const ReliableOrderedMessage = struct {
    sequence: u32,
    payload: []const u8,
};

pub const ReliableOrderedReceiver = struct {
    next_sequence: u32,
    window_size: usize,
    slot_capacity: usize,
    storage: []u8,
    received: [max_reliable_ordered_window]bool = .{false} ** max_reliable_ordered_window,
    lengths: [max_reliable_ordered_window]usize = .{0} ** max_reliable_ordered_window,

    pub fn init(start_sequence: u32, window_size: usize, slot_capacity: usize, storage: []u8) ReliableOrderedError!ReliableOrderedReceiver {
        if (window_size == 0 or window_size > max_reliable_ordered_window or slot_capacity == 0) return error.InvalidConfiguration;
        const required = std.math.mul(usize, window_size, slot_capacity) catch return error.StorageTooSmall;
        if (storage.len < required) return error.StorageTooSmall;
        return .{
            .next_sequence = start_sequence,
            .window_size = window_size,
            .slot_capacity = slot_capacity,
            .storage = storage,
        };
    }

    pub fn receive(self: *ReliableOrderedReceiver, sequence: u32, payload: []const u8) ReliableReceiveResult {
        if (payload.len > self.slot_capacity) return .payload_too_large;
        const distance = sequence -% self.next_sequence;
        if (distance >= self.window_size) return .out_of_window;
        const index: usize = @intCast(sequence % @as(u32, @intCast(self.window_size)));
        if (self.received[index]) return .duplicate;
        const start = index * self.slot_capacity;
        @memcpy(self.storage[start .. start + payload.len], payload);
        self.lengths[index] = payload.len;
        self.received[index] = true;
        return .accepted;
    }

    pub fn drain(self: *ReliableOrderedReceiver, output: []ReliableOrderedMessage) usize {
        var count: usize = 0;
        while (count < output.len) {
            const index: usize = @intCast(self.next_sequence % @as(u32, @intCast(self.window_size)));
            if (!self.received[index]) break;
            const start = index * self.slot_capacity;
            output[count] = .{
                .sequence = self.next_sequence,
                .payload = self.storage[start .. start + self.lengths[index]],
            };
            self.received[index] = false;
            self.lengths[index] = 0;
            self.next_sequence +%= 1;
            count += 1;
        }
        return count;
    }
};

test "reliable ordered delivery drains exactly once in sequence order" {
    var storage: [16]u8 = undefined;
    var receiver = try ReliableOrderedReceiver.init(10, 4, 4, storage[0..]);
    try std.testing.expectEqual(ReliableReceiveResult.accepted, receiver.receive(11, "two"));
    try std.testing.expectEqual(ReliableReceiveResult.accepted, receiver.receive(10, "one"));
    try std.testing.expectEqual(ReliableReceiveResult.duplicate, receiver.receive(10, "one"));
    var output: [4]ReliableOrderedMessage = undefined;
    try std.testing.expectEqual(@as(usize, 2), receiver.drain(output[0..]));
    try std.testing.expectEqual(@as(u32, 10), output[0].sequence);
    try std.testing.expectEqualStrings("one", output[0].payload);
    try std.testing.expectEqual(@as(u32, 11), output[1].sequence);
    try std.testing.expectEqualStrings("two", output[1].payload);
}

test "reliable ordered delivery bounds windows and payload slots" {
    var storage: [8]u8 = undefined;
    var receiver = try ReliableOrderedReceiver.init(std.math.maxInt(u32) - 1, 2, 4, storage[0..]);
    try std.testing.expectEqual(ReliableReceiveResult.accepted, receiver.receive(std.math.maxInt(u32), "wrap"));
    try std.testing.expectEqual(ReliableReceiveResult.out_of_window, receiver.receive(1, "late"));
    try std.testing.expectEqual(ReliableReceiveResult.payload_too_large, receiver.receive(std.math.maxInt(u32) - 1, "large"));
    try std.testing.expectError(error.StorageTooSmall, ReliableOrderedReceiver.init(0, 2, 4, storage[0..7]));
}
