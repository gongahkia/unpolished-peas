const std = @import("std");
const fragmentation = @import("message_fragmentation.zig");

pub const max_reassembly_messages: usize = 16;
pub const MessageReassemblyError = error{ InvalidConfiguration, StorageTooSmall, CapacityExceeded, ClockRegression, MalformedFragment, SetMismatch, FragmentConflict };

pub const MessageReassemblyConfig = struct {
    maximum_message_bytes: usize,
    fragment_payload_bytes: usize,
    expiry_ns: u64,
    maximum_inflight_messages: usize = max_reassembly_messages,
};

pub const ReassemblyResult = union(enum) {
    pending,
    duplicate,
    complete: []u8,
};

const ReassemblyState = struct {
    message_id: u64,
    count: u16,
    storage_index: usize,
    received: [fragmentation.max_message_fragments]bool = .{false} ** fragmentation.max_message_fragments,
    lengths: [fragmentation.max_message_fragments]usize = .{0} ** fragmentation.max_message_fragments,
    received_count: usize = 0,
    total_length: ?usize = null,
    last_update_ns: u64,
};

pub const MessageReassembler = struct {
    config: MessageReassemblyConfig,
    storage: []u8,
    states: [max_reassembly_messages]?ReassemblyState = .{null} ** max_reassembly_messages,
    last_now_ns: ?u64 = null,

    pub fn init(config: MessageReassemblyConfig, storage: []u8) MessageReassemblyError!MessageReassembler {
        if (config.maximum_message_bytes == 0 or config.fragment_payload_bytes == 0 or config.fragment_payload_bytes > config.maximum_message_bytes or config.expiry_ns == 0 or config.maximum_inflight_messages == 0 or config.maximum_inflight_messages > max_reassembly_messages) return error.InvalidConfiguration;
        const required = std.math.mul(usize, config.maximum_message_bytes, config.maximum_inflight_messages) catch return error.StorageTooSmall;
        if (storage.len < required) return error.StorageTooSmall;
        return .{ .config = config, .storage = storage };
    }

    pub fn accept(self: *MessageReassembler, fragment: fragmentation.MessageFragment, now_ns: u64) MessageReassemblyError!ReassemblyResult {
        _ = try self.expire(now_ns);
        try self.validate(fragment);
        if (self.find(fragment.message_id)) |index| return self.store(index, fragment, now_ns);
        const index = self.find_free() orelse return error.CapacityExceeded;
        self.states[index] = .{ .message_id = fragment.message_id, .count = fragment.count, .storage_index = index, .last_update_ns = now_ns };
        return self.store(index, fragment, now_ns);
    }

    pub fn expire(self: *MessageReassembler, now_ns: u64) MessageReassemblyError!usize {
        if (self.last_now_ns) |previous| if (now_ns < previous) return error.ClockRegression;
        self.last_now_ns = now_ns;
        var expired: usize = 0;
        for (&self.states) |*slot| {
            const state = slot.* orelse continue;
            if (now_ns - state.last_update_ns >= self.config.expiry_ns) {
                slot.* = null;
                expired += 1;
            }
        }
        return expired;
    }

    fn validate(self: MessageReassembler, fragment: fragmentation.MessageFragment) MessageReassemblyError!void {
        if (fragment.message_id == 0 or fragment.count == 0 or fragment.count > fragmentation.max_message_fragments or fragment.index >= fragment.count or fragment.payload.len > self.config.fragment_payload_bytes or (fragment.count > 1 and fragment.payload.len == 0) or (fragment.index + 1 < fragment.count and fragment.payload.len != self.config.fragment_payload_bytes)) return error.MalformedFragment;
        const maximum = std.math.mul(usize, @as(usize, fragment.count), self.config.fragment_payload_bytes) catch return error.MalformedFragment;
        if (maximum > self.config.maximum_message_bytes) return error.MalformedFragment;
    }

    fn store(self: *MessageReassembler, state_index: usize, fragment: fragmentation.MessageFragment, now_ns: u64) MessageReassemblyError!ReassemblyResult {
        const state = &self.states[state_index].?;
        if (state.count != fragment.count) return error.SetMismatch;
        const fragment_index: usize = fragment.index;
        const base = state.storage_index * self.config.maximum_message_bytes;
        const start = base + fragment_index * self.config.fragment_payload_bytes;
        const end = start + fragment.payload.len;
        if (state.received[fragment_index]) {
            if (state.lengths[fragment_index] != fragment.payload.len or !std.mem.eql(u8, self.storage[start..end], fragment.payload)) return error.FragmentConflict;
            state.last_update_ns = now_ns;
            return .duplicate;
        }
        @memcpy(self.storage[start..end], fragment.payload);
        state.received[fragment_index] = true;
        state.lengths[fragment_index] = fragment.payload.len;
        state.received_count += 1;
        state.last_update_ns = now_ns;
        if (fragment.index + 1 == fragment.count) state.total_length = fragment_index * self.config.fragment_payload_bytes + fragment.payload.len;
        if (state.received_count != state.count or state.total_length == null) return .pending;
        const message = self.storage[base .. base + state.total_length.?];
        self.states[state_index] = null;
        return .{ .complete = message };
    }

    fn find(self: MessageReassembler, message_id: u64) ?usize {
        for (self.states, 0..) |slot, index| {
            const state = slot orelse continue;
            if (state.message_id == message_id) return index;
        }
        return null;
    }

    fn find_free(self: MessageReassembler) ?usize {
        for (self.states[0..self.config.maximum_inflight_messages], 0..) |slot, index| if (slot == null) return index;
        return null;
    }
};

test "message reassembly deduplicates out-of-order fragments and returns complete storage" {
    var storage: [120]u8 = undefined;
    var reassembler = try MessageReassembler.init(.{ .maximum_message_bytes = 60, .fragment_payload_bytes = 20, .expiry_ns = 10, .maximum_inflight_messages = 2 }, storage[0..]);
    const first = fragmentation.MessageFragment{ .message_id = 1, .index = 0, .count = 3, .payload = "abcdefghijklmnopqrst" };
    const second = fragmentation.MessageFragment{ .message_id = 1, .index = 1, .count = 3, .payload = "uvwxyzABCDEFGHIJKLMN" };
    const last = fragmentation.MessageFragment{ .message_id = 1, .index = 2, .count = 3, .payload = "tail" };
    try std.testing.expectEqual(ReassemblyResult.pending, try reassembler.accept(second, 0));
    try std.testing.expectEqual(ReassemblyResult.pending, try reassembler.accept(first, 1));
    try std.testing.expectEqual(ReassemblyResult.duplicate, try reassembler.accept(first, 2));
    const complete = try reassembler.accept(last, 3);
    try std.testing.expectEqualStrings("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNtail", complete.complete);
}

test "message reassembly rejects malformed sets expires state and enforces capacity" {
    var storage: [20]u8 = undefined;
    try std.testing.expectError(error.InvalidConfiguration, MessageReassembler.init(.{ .maximum_message_bytes = 20, .fragment_payload_bytes = 10, .expiry_ns = 0 }, storage[0..]));
    var reassembler = try MessageReassembler.init(.{ .maximum_message_bytes = 20, .fragment_payload_bytes = 10, .expiry_ns = 5, .maximum_inflight_messages = 1 }, storage[0..]);
    const first = fragmentation.MessageFragment{ .message_id = 1, .index = 0, .count = 2, .payload = "0123456789" };
    try std.testing.expectEqual(ReassemblyResult.pending, try reassembler.accept(first, 0));
    try std.testing.expectError(error.FragmentConflict, reassembler.accept(.{ .message_id = 1, .index = 0, .count = 2, .payload = "abcdefghij" }, 1));
    try std.testing.expectError(error.CapacityExceeded, reassembler.accept(.{ .message_id = 2, .index = 0, .count = 2, .payload = "0123456789" }, 1));
    try std.testing.expectEqual(@as(usize, 1), try reassembler.expire(5));
    try std.testing.expectError(error.ClockRegression, reassembler.expire(4));
    try std.testing.expectError(error.MalformedFragment, reassembler.accept(.{ .message_id = 3, .index = 0, .count = 2, .payload = "short" }, 6));
    try std.testing.expectError(error.StorageTooSmall, MessageReassembler.init(.{ .maximum_message_bytes = 20, .fragment_payload_bytes = 10, .expiry_ns = 1 }, storage[0..19]));
}
