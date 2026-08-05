const std = @import("std");

pub const stun_header_bytes: usize = 20;
pub const stun_magic_cookie: u32 = 0x2112A442;
pub const stun_fingerprint_xor: u32 = 0x5354554e;
pub const StunCodecError = error{ BufferTooSmall, MalformedMessage, InvalidType, InvalidLength, InvalidCookie, InvalidAttribute, InvalidAddress, InvalidErrorCode, InvalidFingerprint };
pub const StunClass = enum(u2) { request = 0, indication = 1, success_response = 2, error_response = 3 };
pub const StunHeader = struct { method: u16, class: StunClass, transaction_id: [12]u8 };
pub const StunAttribute = struct { kind: u16, value: []const u8 };
pub const StunAddress = union(enum) { ipv4: struct { octets: [4]u8, port: u16 }, ipv6: struct { octets: [16]u8, port: u16 } };
pub const StunErrorCode = struct { code: u16, reason: []const u8 };

pub fn encode_stun_message(header: StunHeader, attributes: []const StunAttribute, output: []u8) StunCodecError![]u8 {
    const message_type = try encode_type(header.method, header.class);
    var length: usize = 0;
    for (attributes) |attribute| {
        const padded = std.mem.alignForward(usize, attribute.value.len, 4);
        length = std.math.add(usize, length, 4 + padded) catch return error.InvalidLength;
    }
    if (length > std.math.maxInt(u16) or output.len < stun_header_bytes + length) return error.BufferTooSmall;
    std.mem.writeInt(u16, output[0..2], message_type, .big);
    std.mem.writeInt(u16, output[2..4], @intCast(length), .big);
    std.mem.writeInt(u32, output[4..8], stun_magic_cookie, .big);
    @memcpy(output[8..20], &header.transaction_id);
    var offset: usize = stun_header_bytes;
    for (attributes) |attribute| {
        std.mem.writeInt(u16, output[offset..][0..2], attribute.kind, .big);
        std.mem.writeInt(u16, output[offset + 2 ..][0..2], @intCast(attribute.value.len), .big);
        @memcpy(output[offset + 4 ..][0..attribute.value.len], attribute.value);
        const padded = std.mem.alignForward(usize, attribute.value.len, 4);
        @memset(output[offset + 4 + attribute.value.len ..][0 .. padded - attribute.value.len], 0);
        offset += 4 + padded;
    }
    return output[0..offset];
}

pub fn decode_stun_message(input: []const u8, attributes: []StunAttribute) StunCodecError!struct { header: StunHeader, count: usize } {
    if (input.len < stun_header_bytes) return error.MalformedMessage;
    const encoded_type = std.mem.readInt(u16, input[0..2], .big);
    const header = StunHeader{ .method = try decode_method(encoded_type), .class = try decode_class(encoded_type), .transaction_id = input[8..20].* };
    const length: usize = std.mem.readInt(u16, input[2..4], .big);
    if (length % 4 != 0 or input.len != stun_header_bytes + length) return error.InvalidLength;
    if (std.mem.readInt(u32, input[4..8], .big) != stun_magic_cookie) return error.InvalidCookie;
    var offset: usize = stun_header_bytes;
    var count: usize = 0;
    while (offset < input.len) {
        if (input.len - offset < 4) return error.InvalidAttribute;
        const value_len: usize = std.mem.readInt(u16, input[offset + 2 ..][0..2], .big);
        const padded = std.mem.alignForward(usize, value_len, 4);
        if (input.len - offset < 4 + padded) return error.InvalidAttribute;
        if (count == attributes.len) return error.BufferTooSmall;
        attributes[count] = .{ .kind = std.mem.readInt(u16, input[offset..][0..2], .big), .value = input[offset + 4 ..][0..value_len] };
        count += 1;
        offset += 4 + padded;
    }
    return .{ .header = header, .count = count };
}

pub fn encode_xor_address(address: StunAddress, transaction_id: [12]u8, output: []u8) StunCodecError![]u8 {
    const cookie = std.mem.toBytes(std.mem.nativeToBig(u32, stun_magic_cookie));
    switch (address) {
        .ipv4 => |ipv4| {
            if (output.len < 8) return error.BufferTooSmall;
            output[0] = 0;
            output[1] = 1;
            std.mem.writeInt(u16, output[2..4], ipv4.port ^ @as(u16, @truncate(stun_magic_cookie >> 16)), .big);
            for (ipv4.octets, 0..) |octet, i| output[4 + i] = octet ^ cookie[i];
            return output[0..8];
        },
        .ipv6 => |ipv6| {
            if (output.len < 20) return error.BufferTooSmall;
            output[0] = 0;
            output[1] = 2;
            std.mem.writeInt(u16, output[2..4], ipv6.port ^ @as(u16, @truncate(stun_magic_cookie >> 16)), .big);
            for (ipv6.octets, 0..) |octet, index| output[4 + index] = octet ^ if (index < 4) cookie[index] else transaction_id[index - 4];
            return output[0..20];
        },
    }
}

pub fn decode_xor_address(input: []const u8, transaction_id: [12]u8) StunCodecError!StunAddress {
    if (input.len != 8 and input.len != 20 or input[0] != 0) return error.InvalidAddress;
    const cookie = std.mem.toBytes(std.mem.nativeToBig(u32, stun_magic_cookie));
    const port = std.mem.readInt(u16, input[2..4], .big) ^ @as(u16, @truncate(stun_magic_cookie >> 16));
    return switch (input[1]) {
        1 => blk: {
            if (input.len != 8) return error.InvalidAddress;
            var octets: [4]u8 = undefined;
            for (&octets, 0..) |*octet, index| octet.* = input[4 + index] ^ cookie[index];
            break :blk .{ .ipv4 = .{ .octets = octets, .port = port } };
        },
        2 => blk: {
            if (input.len != 20) return error.InvalidAddress;
            var octets: [16]u8 = undefined;
            for (&octets, 0..) |*octet, index| octet.* = input[4 + index] ^ if (index < 4) cookie[index] else transaction_id[index - 4];
            break :blk .{ .ipv6 = .{ .octets = octets, .port = port } };
        },
        else => error.InvalidAddress,
    };
}

pub fn encode_error_code(value: StunErrorCode, output: []u8) StunCodecError![]u8 {
    if (value.code < 300 or value.code > 699 or output.len < 4 + value.reason.len) return error.InvalidErrorCode;
    @memset(output[0..2], 0);
    output[2] = @intCast(value.code / 100);
    output[3] = @intCast(value.code % 100);
    @memcpy(output[4..][0..value.reason.len], value.reason);
    return output[0 .. 4 + value.reason.len];
}
pub fn decode_error_code(input: []const u8) StunCodecError!StunErrorCode {
    if (input.len < 4 or input[0] != 0 or input[1] != 0 or input[2] < 3 or input[2] > 6 or input[3] > 99) return error.InvalidErrorCode;
    return .{ .code = @as(u16, input[2]) * 100 + input[3], .reason = input[4..] };
}
pub fn stun_fingerprint(input: []const u8) u32 {
    return crc32(input) ^ stun_fingerprint_xor;
}
pub fn verify_stun_fingerprint(input: []const u8, fingerprint: u32) StunCodecError!void {
    if (stun_fingerprint(input) != fingerprint) return error.InvalidFingerprint;
}

fn encode_type(method: u16, class: StunClass) StunCodecError!u16 {
    if (method > 0x0fff) return error.InvalidType;
    const c: u16 = @intFromEnum(class);
    return (method & 0x000f) | ((method & 0x0070) << 1) | ((method & 0x0f80) << 2) | ((c & 1) << 4) | ((c & 2) << 7);
}
fn decode_method(value: u16) StunCodecError!u16 {
    if (value & 0xc000 != 0) return error.InvalidType;
    return (value & 0x000f) | ((value >> 1) & 0x0070) | ((value >> 2) & 0x0f80);
}
fn decode_class(value: u16) StunCodecError!StunClass {
    if (value & 0xc000 != 0) return error.InvalidType;
    return @enumFromInt(((value >> 4) & 1) | ((value >> 7) & 2));
}
fn crc32(input: []const u8) u32 {
    var crc: u32 = 0xffffffff;
    for (input) |byte| {
        crc ^= byte;
        for (0..8) |_| crc = if (crc & 1 != 0) (crc >> 1) ^ 0xedb88320 else crc >> 1;
    }
    return ~crc;
}

test "STUN codec encodes bounded headers attributes XOR addresses errors and fingerprints" {
    const header = StunHeader{ .method = 1, .class = .request, .transaction_id = .{0} ** 12 };
    const attrs = [_]StunAttribute{.{ .kind = 0x0006, .value = "u" }};
    var bytes: [28]u8 = undefined;
    const encoded = try encode_stun_message(header, &attrs, bytes[0..]);
    var decoded: [1]StunAttribute = undefined;
    const message = try decode_stun_message(encoded, decoded[0..]);
    try std.testing.expectEqual(header, message.header);
    try std.testing.expectEqualStrings("u", decoded[0].value);
    var address: [8]u8 = undefined;
    const xor_address = try encode_xor_address(.{ .ipv4 = .{ .octets = .{ 1, 2, 3, 4 }, .port = 3478 } }, header.transaction_id, address[0..]);
    try std.testing.expectEqual(StunAddress{ .ipv4 = .{ .octets = .{ 1, 2, 3, 4 }, .port = 3478 } }, try decode_xor_address(xor_address, header.transaction_id));
    var ipv6: [20]u8 = undefined;
    const xor_ipv6 = try encode_xor_address(.{ .ipv6 = .{ .octets = .{0} ** 15 ++ .{1}, .port = 3478 } }, header.transaction_id, ipv6[0..]);
    try std.testing.expectEqual(StunAddress{ .ipv6 = .{ .octets = .{0} ** 15 ++ .{1}, .port = 3478 } }, try decode_xor_address(xor_ipv6, header.transaction_id));
    var error_bytes: [7]u8 = undefined;
    try std.testing.expectEqual(StunErrorCode{ .code = 400, .reason = "bad" }, try decode_error_code(try encode_error_code(.{ .code = 400, .reason = "bad" }, error_bytes[0..])));
    try verify_stun_fingerprint(encoded, stun_fingerprint(encoded));
}

test "bounded STUN codec fuzz corpus retains parser limits" {
    var prng = std.Random.DefaultPrng.init(0x4871_9f2c_5a8d_e306);
    const random = prng.random();
    var input: [256]u8 = undefined;
    var attributes: [8]StunAttribute = undefined;
    var transaction_id: [12]u8 = undefined;
    var iteration: usize = 0;
    while (iteration < 512) : (iteration += 1) {
        const length = random.uintLessThan(usize, input.len + 1);
        random.bytes(input[0..length]);
        random.bytes(&transaction_id);
        if (decode_stun_message(input[0..length], attributes[0..]) catch null) |message| {
            try std.testing.expect(message.count <= attributes.len);
            try std.testing.expect(message.header.method <= 0x0fff);
        }
        _ = decode_xor_address(input[0..length], transaction_id) catch {};
        _ = decode_error_code(input[0..length]) catch {};
        verify_stun_fingerprint(input[0..length], random.int(u32)) catch {};
    }
    var encoded: [stun_header_bytes]u8 = undefined;
    const frame = try encode_stun_message(.{ .method = 1, .class = .request, .transaction_id = .{0} ** 12 }, &.{}, encoded[0..]);
    try std.testing.expectEqual(@as(usize, 0), (try decode_stun_message(frame, attributes[0..])).count);
    encoded[4] +%= 1;
    try std.testing.expectError(error.InvalidCookie, decode_stun_message(encoded[0..], attributes[0..]));
}
