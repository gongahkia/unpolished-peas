const std = @import("std");
pub const mtu: usize = 1200;
pub const header_bytes: usize = 12;
pub const fragment_bytes: usize = mtu - header_bytes;
pub const max_fragments: usize = 16;
pub const max_message_bytes: usize = fragment_bytes * max_fragments;
pub const Header = struct { sequence: u32, message: u32, index: u16, count: u16 };
pub fn encode(out: []u8, header: Header, payload: []const u8) ![]u8 {
    if (payload.len > fragment_bytes or header.count == 0 or header.count > max_fragments or header.index >= header.count) return error.InvalidFrame;
    if (out.len < header_bytes + payload.len) return error.BufferTooSmall;
    std.mem.writeInt(u32, out[0..4], header.sequence, .little);
    std.mem.writeInt(u32, out[4..8], header.message, .little);
    std.mem.writeInt(u16, out[8..10], header.index, .little);
    std.mem.writeInt(u16, out[10..12], header.count, .little);
    @memcpy(out[header_bytes .. header_bytes + payload.len], payload);
    return out[0 .. header_bytes + payload.len];
}
pub fn decode(input: []const u8) !struct { header: Header, payload: []const u8 } {
    if (input.len < header_bytes or input.len > mtu) return error.InvalidFrame;
    const header = Header{ .sequence = std.mem.readInt(u32, input[0..4], .little), .message = std.mem.readInt(u32, input[4..8], .little), .index = std.mem.readInt(u16, input[8..10], .little), .count = std.mem.readInt(u16, input[10..12], .little) };
    if (header.count == 0 or header.count > max_fragments or header.index >= header.count) return error.InvalidFrame;
    return .{ .header = header, .payload = input[header_bytes..] };
}
pub const Reassembler = struct { // owns partial frame buffers allocated by init; call deinit once and free completed results with its allocator.
    allocator: std.mem.Allocator,
    message: ?u32 = null,
    count: u16 = 0,
    received: u16 = 0,
    expires_at: u64 = 0,
    parts: [max_fragments]?[]u8 = [_]?[]u8{null} ** max_fragments,
    pub fn init(allocator: std.mem.Allocator) Reassembler {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Reassembler) void {
        self.reset();
        self.* = undefined;
    }
    pub fn push(self: *Reassembler, now: u64, frame: anytype) !?[]u8 {
        if (self.message != null and now >= self.expires_at) self.reset();
        if (self.message == null) {
            self.message = frame.header.message;
            self.count = frame.header.count;
            self.expires_at = now + 5000;
        }
        if (self.message.? != frame.header.message or self.count != frame.header.count) return error.ReassemblyConflict;
        const index: usize = frame.header.index;
        if (self.parts[index] != null) return error.DuplicateFragment;
        self.parts[index] = try self.allocator.dupe(u8, frame.payload);
        self.received += 1;
        if (self.received != self.count) return null;
        var len: usize = 0;
        for (self.parts[0..self.count]) |part| len += part.?.len;
        if (len > max_message_bytes) return error.MessageTooLarge;
        const result = try self.allocator.alloc(u8, len);
        var at: usize = 0;
        for (self.parts[0..self.count]) |part| {
            @memcpy(result[at..][0..part.?.len], part.?);
            at += part.?.len;
        }
        self.reset();
        return result;
    }
    fn reset(self: *Reassembler) void {
        for (&self.parts) |*part| if (part.*) |bytes| self.allocator.free(bytes);
        self.parts = [_]?[]u8{null} ** max_fragments;
        self.message = null;
        self.count = 0;
        self.received = 0;
        self.expires_at = 0;
    }
};
test "frame rejects malformed mtu and fragment bounds" {
    var bytes: [mtu + 1]u8 = undefined;
    try std.testing.expectError(error.InvalidFrame, decode(&bytes));
    var out: [mtu]u8 = undefined;
    const frame = try encode(&out, .{ .sequence = 1, .message = 2, .index = 0, .count = 1 }, "ok");
    const got = try decode(frame);
    try std.testing.expectEqual(@as(u32, 1), got.header.sequence);
    try std.testing.expectEqualStrings("ok", got.payload);
}
