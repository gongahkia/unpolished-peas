const std = @import("std");

pub const SequencedReceiveResult = enum {
    delivered,
    stale,
    duplicate,
};

pub const UnreliableSequencedReceiver = struct {
    latest_sequence: ?u32 = null,

    pub fn receive(self: *UnreliableSequencedReceiver, sequence: u32) SequencedReceiveResult {
        if (self.latest_sequence) |latest| {
            if (sequence == latest) return .duplicate;
            if (!is_newer_sequence(sequence, latest)) return .stale;
        }
        self.latest_sequence = sequence;
        return .delivered;
    }
};

pub fn is_newer_sequence(candidate: u32, reference: u32) bool {
    const distance = candidate -% reference;
    return distance != 0 and distance < 0x8000_0000;
}

test "unreliable sequenced delivery keeps only newest messages" {
    var receiver = UnreliableSequencedReceiver{};
    try std.testing.expectEqual(SequencedReceiveResult.delivered, receiver.receive(5));
    try std.testing.expectEqual(SequencedReceiveResult.stale, receiver.receive(4));
    try std.testing.expectEqual(SequencedReceiveResult.duplicate, receiver.receive(5));
    try std.testing.expectEqual(SequencedReceiveResult.delivered, receiver.receive(6));
}

test "unreliable sequenced delivery handles u32 wraparound" {
    var receiver = UnreliableSequencedReceiver{ .latest_sequence = std.math.maxInt(u32) };
    try std.testing.expect(is_newer_sequence(0, std.math.maxInt(u32)));
    try std.testing.expectEqual(SequencedReceiveResult.delivered, receiver.receive(0));
    try std.testing.expectEqual(SequencedReceiveResult.stale, receiver.receive(std.math.maxInt(u32)));
}
