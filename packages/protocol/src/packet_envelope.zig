const std = @import("std");
const envelope = @import("wire_envelope.zig");

pub const packet_header_bytes: usize = 10;
pub const max_packet_payload_bytes: usize = 65_507;
pub const PacketEnvelopeError = envelope.CompatibilityError || error{ PayloadTooLarge, BufferTooSmall, MalformedPacket };

pub fn encode_packet(value: envelope.WireEnvelope, output: []u8) PacketEnvelopeError![]u8 {
    try envelope.validate_envelope(value);
    if (value.payload.len > max_packet_payload_bytes) return error.PayloadTooLarge;
    const total = std.math.add(usize, packet_header_bytes, value.payload.len) catch return error.PayloadTooLarge;
    if (output.len < total) return error.BufferTooSmall;
    std.mem.writeInt(u16, output[0..2], value.version.major, .big);
    std.mem.writeInt(u16, output[2..4], value.version.minor, .big);
    std.mem.writeInt(u16, output[4..6], value.extension_id, .big);
    std.mem.writeInt(u32, output[6..10], @intCast(value.payload.len), .big);
    @memcpy(output[packet_header_bytes..total], value.payload);
    return output[0..total];
}

pub fn decode_packet(input: []const u8) PacketEnvelopeError!envelope.WireEnvelope {
    if (input.len < packet_header_bytes) return error.MalformedPacket;
    const payload_len: usize = std.mem.readInt(u32, input[6..10], .big);
    if (payload_len > max_packet_payload_bytes) return error.PayloadTooLarge;
    const total = std.math.add(usize, packet_header_bytes, payload_len) catch return error.MalformedPacket;
    if (input.len != total) return error.MalformedPacket;
    const value = envelope.WireEnvelope{
        .version = .{
            .major = std.mem.readInt(u16, input[0..2], .big),
            .minor = std.mem.readInt(u16, input[2..4], .big),
        },
        .extension_id = std.mem.readInt(u16, input[4..6], .big),
        .payload = input[packet_header_bytes..],
    };
    try envelope.validate_envelope(value);
    return value;
}

test "versioned packet envelopes encode and decode bounded payloads" {
    const value = envelope.WireEnvelope{ .version = envelope.v1_version, .extension_id = 0, .payload = "packet" };
    var storage: [packet_header_bytes + value.payload.len]u8 = undefined;
    const encoded = try encode_packet(value, storage[0..]);
    const decoded = try decode_packet(encoded);
    try std.testing.expectEqual(value.version, decoded.version);
    try std.testing.expectEqual(value.extension_id, decoded.extension_id);
    try std.testing.expectEqualStrings(value.payload, decoded.payload);
}

test "versioned packet envelopes reject malformed bounded inputs" {
    var short: [packet_header_bytes - 1]u8 = undefined;
    try std.testing.expectError(error.MalformedPacket, decode_packet(short[0..]));
    var output: [packet_header_bytes]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, encode_packet(.{ .version = envelope.v1_version, .extension_id = 0, .payload = "x" }, output[0..]));
    var invalid_version: [packet_header_bytes]u8 = .{0} ** packet_header_bytes;
    std.mem.writeInt(u16, invalid_version[0..2], 2, .big);
    try std.testing.expectError(error.VersionMismatch, decode_packet(invalid_version[0..]));
}
