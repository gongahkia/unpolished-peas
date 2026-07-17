const std = @import("std");

pub const max_transport_fragments: usize = 64;
pub const TransportFragmentError = error{ InvalidBudget, MessageTooLarge, FragmentOutOfRange, MalformedFragment, ReassemblyMismatch, ReassemblyStorageTooSmall };

pub const TransportFragment = struct {
    message_id: u32,
    index: u16,
    count: u16,
    payload: []const u8,
};

pub const TransportFragmenter = struct {
    payload_budget: usize,

    pub fn init(payload_budget: usize) TransportFragmentError!TransportFragmenter {
        if (payload_budget == 0) return error.InvalidBudget;
        return .{ .payload_budget = payload_budget };
    }

    pub fn fragment_count(self: TransportFragmenter, message: []const u8) TransportFragmentError!u16 {
        const count = if (message.len == 0) 1 else std.math.divCeil(usize, message.len, self.payload_budget) catch return error.MessageTooLarge;
        if (count > max_transport_fragments) return error.MessageTooLarge;
        return @intCast(count);
    }

    pub fn fragment_at(self: TransportFragmenter, message_id: u32, message: []const u8, index: u16) TransportFragmentError!TransportFragment {
        const count = try self.fragment_count(message);
        if (index >= count) return error.FragmentOutOfRange;
        const start = @as(usize, index) * self.payload_budget;
        const end = @min(start + self.payload_budget, message.len);
        return .{ .message_id = message_id, .index = index, .count = count, .payload = message[start..end] };
    }
};

pub const TransportReassembler = struct {
    payload_budget: usize,
    storage: []u8,
    message_id: ?u32 = null,
    fragment_count: u16 = 0,
    received: [max_transport_fragments]bool = .{false} ** max_transport_fragments,
    received_count: usize = 0,
    total_length: usize = 0,

    pub fn init(payload_budget: usize, storage: []u8) TransportFragmentError!TransportReassembler {
        if (payload_budget == 0) return error.InvalidBudget;
        return .{ .payload_budget = payload_budget, .storage = storage };
    }

    pub fn accept(self: *TransportReassembler, fragment: TransportFragment) TransportFragmentError!?[]u8 {
        if (fragment.count == 0 or fragment.count > max_transport_fragments or fragment.index >= fragment.count or fragment.payload.len > self.payload_budget) return error.MalformedFragment;
        if (fragment.index + 1 < fragment.count and fragment.payload.len != self.payload_budget) return error.MalformedFragment;
        const required = @as(usize, fragment.count) * self.payload_budget;
        if (required > self.storage.len and fragment.index + 1 < fragment.count) return error.ReassemblyStorageTooSmall;
        if (self.message_id) |message_id| {
            if (message_id != fragment.message_id or self.fragment_count != fragment.count) return error.ReassemblyMismatch;
        } else {
            self.message_id = fragment.message_id;
            self.fragment_count = fragment.count;
        }
        const start = @as(usize, fragment.index) * self.payload_budget;
        const end = start + fragment.payload.len;
        if (end > self.storage.len) return error.ReassemblyStorageTooSmall;
        if (!self.received[fragment.index]) {
            @memcpy(self.storage[start..end], fragment.payload);
            self.received[fragment.index] = true;
            self.received_count += 1;
        }
        if (fragment.index + 1 == fragment.count) self.total_length = end;
        if (self.received_count != fragment.count or self.total_length == 0) return null;
        const message = self.storage[0..self.total_length];
        self.reset();
        return message;
    }

    fn reset(self: *TransportReassembler) void {
        self.message_id = null;
        self.fragment_count = 0;
        self.received = .{false} ** max_transport_fragments;
        self.received_count = 0;
        self.total_length = 0;
    }
};

test "fragment handoff bounds messages and reassembles caller-owned storage" {
    const fragmenter = try TransportFragmenter.init(5);
    const message = "hello, world";
    try std.testing.expectEqual(@as(u16, 3), try fragmenter.fragment_count(message));
    var storage: [15]u8 = undefined;
    var reassembler = try TransportReassembler.init(5, storage[0..]);
    try std.testing.expect((try reassembler.accept(try fragmenter.fragment_at(7, message, 1))) == null);
    try std.testing.expect((try reassembler.accept(try fragmenter.fragment_at(7, message, 0))) == null);
    try std.testing.expectEqualStrings(message, (try reassembler.accept(try fragmenter.fragment_at(7, message, 2))).?);
}

test "fragment handoff rejects oversized and malformed input" {
    const fragmenter = try TransportFragmenter.init(1);
    const oversized = [_]u8{0} ** (max_transport_fragments + 1);
    try std.testing.expectError(error.MessageTooLarge, fragmenter.fragment_count(&oversized));
    var storage: [5]u8 = undefined;
    var reassembler = try TransportReassembler.init(5, storage[0..]);
    try std.testing.expectError(error.MalformedFragment, reassembler.accept(.{ .message_id = 1, .index = 0, .count = 2, .payload = "bad" }));
}
