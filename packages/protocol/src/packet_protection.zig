const std = @import("std");
const packet = @import("packet_envelope.zig");

const aead = std.crypto.aead.chacha_poly.ChaCha20Poly1305;

pub const packet_protection_key_bytes: usize = aead.key_length;
pub const packet_protection_nonce_prefix_bytes: usize = aead.nonce_length - @sizeOf(u64);
pub const packet_protection_nonce_bytes: usize = aead.nonce_length;
pub const packet_protection_tag_bytes: usize = aead.tag_length;
pub const packet_protection_frame_header_bytes: usize = @sizeOf(u64);
pub const PacketProtectionError = error{ PayloadTooLarge, OutputTooSmall, MalformedFrame, SequenceExhausted, AuthenticationFailed };

pub const PacketProtectionKey = struct {
    key: [packet_protection_key_bytes]u8,
    nonce_prefix: [packet_protection_nonce_prefix_bytes]u8,

    pub fn init(key: [packet_protection_key_bytes]u8, nonce_prefix: [packet_protection_nonce_prefix_bytes]u8) PacketProtectionKey {
        return .{ .key = key, .nonce_prefix = nonce_prefix };
    }

    pub fn clear(self: *PacketProtectionKey) void {
        std.crypto.secureZero(u8, &self.key);
        self.nonce_prefix = .{0} ** packet_protection_nonce_prefix_bytes;
    }
};

pub const UnprotectedPacket = struct {
    sequence: u64,
    payload: []const u8,
};

pub const PacketProtector = struct {
    key: PacketProtectionKey,
    next_sequence: u64 = 0,
    exhausted: bool = false,

    pub fn init(key: PacketProtectionKey) PacketProtector {
        return .{ .key = key };
    }

    pub fn deinit(self: *PacketProtector) void {
        self.key.clear();
        self.exhausted = true;
    }

    pub fn seal(self: *PacketProtector, payload: []const u8, output: []u8) PacketProtectionError![]u8 {
        if (self.exhausted) return error.SequenceExhausted;
        if (payload.len > packet.max_packet_payload_bytes) return error.PayloadTooLarge;
        const total = packet_protection_frame_header_bytes + payload.len + packet_protection_tag_bytes;
        if (output.len < total) return error.OutputTooSmall;
        const sequence = self.next_sequence;
        std.mem.writeInt(u64, output[0..packet_protection_frame_header_bytes], sequence, .big);
        const ciphertext = output[packet_protection_frame_header_bytes..][0..payload.len];
        const tag: *[packet_protection_tag_bytes]u8 = @ptrCast(output[packet_protection_frame_header_bytes + payload.len .. total].ptr);
        aead.encrypt(ciphertext, tag, payload, output[0..packet_protection_frame_header_bytes], packet_nonce(self.key.nonce_prefix, sequence), self.key.key);
        if (sequence == std.math.maxInt(u64)) self.exhausted = true else self.next_sequence += 1;
        return output[0..total];
    }

    pub fn open(self: PacketProtector, input: []const u8, output: []u8) PacketProtectionError!UnprotectedPacket {
        if (input.len < packet_protection_frame_header_bytes + packet_protection_tag_bytes) return error.MalformedFrame;
        const payload_len = input.len - packet_protection_frame_header_bytes - packet_protection_tag_bytes;
        if (payload_len > packet.max_packet_payload_bytes) return error.PayloadTooLarge;
        if (output.len < payload_len) return error.OutputTooSmall;
        const sequence = std.mem.readInt(u64, input[0..packet_protection_frame_header_bytes], .big);
        const ciphertext = input[packet_protection_frame_header_bytes..][0..payload_len];
        const tag: *const [packet_protection_tag_bytes]u8 = @ptrCast(input[input.len - packet_protection_tag_bytes ..].ptr);
        aead.decrypt(output[0..payload_len], ciphertext, tag.*, input[0..packet_protection_frame_header_bytes], packet_nonce(self.key.nonce_prefix, sequence), self.key.key) catch {
            std.crypto.secureZero(u8, output[0..payload_len]);
            return error.AuthenticationFailed;
        };
        return .{ .sequence = sequence, .payload = output[0..payload_len] };
    }
};

pub fn packet_nonce(prefix: [packet_protection_nonce_prefix_bytes]u8, sequence: u64) [packet_protection_nonce_bytes]u8 {
    var nonce: [packet_protection_nonce_bytes]u8 = undefined;
    @memcpy(nonce[0..packet_protection_nonce_prefix_bytes], &prefix);
    std.mem.writeInt(u64, nonce[packet_protection_nonce_prefix_bytes..], sequence, .big);
    return nonce;
}

test "packet protection authenticates framed packet payloads with unique nonces" {
    const key = PacketProtectionKey.init([_]u8{5} ** packet_protection_key_bytes, [_]u8{7} ** packet_protection_nonce_prefix_bytes);
    var sender = PacketProtector.init(key);
    defer sender.deinit();
    var receiver = PacketProtector.init(key);
    defer receiver.deinit();
    var first_storage: [packet_protection_frame_header_bytes + 7 + packet_protection_tag_bytes]u8 = undefined;
    const first = try sender.seal("message", first_storage[0..]);
    var second_storage: [packet_protection_frame_header_bytes + 7 + packet_protection_tag_bytes]u8 = undefined;
    const second = try sender.seal("message", second_storage[0..]);
    try std.testing.expect(!std.mem.eql(u8, first, second));
    var output: [7]u8 = undefined;
    const opened = try receiver.open(first, output[0..]);
    try std.testing.expectEqual(@as(u64, 0), opened.sequence);
    try std.testing.expectEqualStrings("message", opened.payload);
    try std.testing.expectEqual(packet_nonce(key.nonce_prefix, 0), packet_nonce(key.nonce_prefix, 0));
    try std.testing.expect(!std.mem.eql(u8, &packet_nonce(key.nonce_prefix, 0), &packet_nonce(key.nonce_prefix, 1)));
}

test "packet protection rejects tampered malformed and exhausted frames" {
    const key = PacketProtectionKey.init([_]u8{2} ** packet_protection_key_bytes, [_]u8{3} ** packet_protection_nonce_prefix_bytes);
    var sender = PacketProtector.init(key);
    defer sender.deinit();
    var receiver = PacketProtector.init(key);
    defer receiver.deinit();
    var storage: [packet_protection_frame_header_bytes + 1 + packet_protection_tag_bytes]u8 = undefined;
    const frame = try sender.seal("x", storage[0..]);
    var output = [_]u8{9};
    storage[0] +%= 1;
    try std.testing.expectError(error.AuthenticationFailed, receiver.open(frame, output[0..]));
    try std.testing.expectEqual(@as(u8, 0), output[0]);
    try std.testing.expectError(error.MalformedFrame, receiver.open(frame[0 .. packet_protection_frame_header_bytes + packet_protection_tag_bytes - 1], output[0..]));
    sender.next_sequence = std.math.maxInt(u64);
    sender.exhausted = false;
    _ = try sender.seal("x", storage[0..]);
    try std.testing.expectError(error.SequenceExhausted, sender.seal("x", storage[0..]));
}
