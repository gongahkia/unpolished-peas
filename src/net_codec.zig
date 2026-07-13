const std = @import("std");

pub const version: u8 = 1;
pub const max_payload_bytes: usize = 1024;
pub const header_bytes: usize = 8;

pub const Kind = enum(u8) { hello = 1, input = 2, snapshot = 3, ping = 4, disconnect = 5 };
pub const Message = struct { kind: Kind, sequence: u32, payload: []const u8 };
pub const OwnedMessage = struct {
    kind: Kind,
    sequence: u32,
    payload: []u8,
    pub fn deinit(self: *OwnedMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
        self.* = undefined;
    }
};

pub fn encodedLen(message: Message) !usize {
    if (message.payload.len > max_payload_bytes) return error.PayloadTooLarge;
    return header_bytes + message.payload.len;
}

pub fn encode(destination: []u8, message: Message) ![]u8 {
    const length = try encodedLen(message);
    if (destination.len < length) return error.BufferTooSmall;
    destination[0] = version;
    destination[1] = @intFromEnum(message.kind);
    std.mem.writeInt(u32, destination[2..6], message.sequence, .little);
    std.mem.writeInt(u16, destination[6..8], @intCast(message.payload.len), .little);
    @memcpy(destination[header_bytes..length], message.payload);
    return destination[0..length];
}

pub fn decode(allocator: std.mem.Allocator, source: []const u8) !OwnedMessage {
    if (source.len < header_bytes) return error.TruncatedHeader;
    if (source[0] != version) return error.UnsupportedVersion;
    const kind = std.meta.intToEnum(Kind, source[1]) catch return error.UnknownKind;
    const payload_len: usize = std.mem.readInt(u16, source[6..8], .little);
    if (payload_len > max_payload_bytes) return error.PayloadTooLarge;
    if (source.len != header_bytes + payload_len) return error.InvalidLength;
    return .{ .kind = kind, .sequence = std.mem.readInt(u32, source[2..6], .little), .payload = try allocator.dupe(u8, source[header_bytes..]) };
}

test "network codec round trips stable little-endian messages" {
    const message = Message{ .kind = .input, .sequence = 0x01020304, .payload = "move" };
    var bytes: [64]u8 = undefined;
    const encoded = try encode(&bytes, message);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 4, 3, 2, 1, 4, 0, 'm', 'o', 'v', 'e' }, encoded);
    var decoded = try decode(std.testing.allocator, encoded);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(Kind.input, decoded.kind);
    try std.testing.expectEqual(@as(u32, 0x01020304), decoded.sequence);
    try std.testing.expectEqualStrings("move", decoded.payload);
}

test "network codec rejects malformed and bounded payloads" {
    var bytes: [header_bytes + max_payload_bytes + 1]u8 = [_]u8{0} ** (header_bytes + max_payload_bytes + 1);
    bytes[0] = version;
    bytes[1] = @intFromEnum(Kind.ping);
    std.mem.writeInt(u16, bytes[6..8], @intCast(max_payload_bytes + 1), .little);
    try std.testing.expectError(error.TruncatedHeader, decode(std.testing.allocator, ""));
    try std.testing.expectError(error.UnsupportedVersion, decode(std.testing.allocator, &.{ 2, 1, 0, 0, 0, 0, 0, 0 }));
    try std.testing.expectError(error.UnknownKind, decode(std.testing.allocator, &.{ 1, 99, 0, 0, 0, 0, 0, 0 }));
    try std.testing.expectError(error.InvalidLength, decode(std.testing.allocator, &.{ 1, 1, 0, 0, 0, 0, 1, 0 }));
    try std.testing.expectError(error.PayloadTooLarge, decode(std.testing.allocator, &bytes));
}
