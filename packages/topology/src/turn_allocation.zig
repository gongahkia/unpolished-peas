const std = @import("std");
const core = @import("minna-san-core");
const protocol = @import("minna-san-protocol");
const transport = @import("minna-san-transport");

pub const TurnAllocationError = protocol.StunCredentialError || protocol.StunCodecError || error{ InvalidConfiguration, NotStarted, Complete, UnexpectedResponse, MissingRelayAddress, MissingLifetime, InvalidLifetime, AllocationRejected };
pub const TurnAllocationConfig = struct { server: transport.Ipv4Address, credentials: protocol.StunLongTermCredentials, requested_lifetime_seconds: u32 };
pub const TurnAllocation = struct { relay: protocol.StunAddress, expires_at_ns: core.TimeNs };

pub const TurnAllocationClient = struct {
    config: TurnAllocationConfig,
    transaction_id: [12]u8,
    started_at_ns: ?core.TimeNs = null,
    allocation: ?TurnAllocation = null,

    pub fn init(config: TurnAllocationConfig, transaction_id: [12]u8) TurnAllocationError!TurnAllocationClient {
        if (config.server.port == 0 or config.requested_lifetime_seconds == 0) return error.InvalidConfiguration;
        try protocol.validate_long_term_credentials(config.credentials);
        return .{ .config = config, .transaction_id = transaction_id };
    }

    pub fn begin(self: *TurnAllocationClient, now_ns: core.TimeNs, output: []u8) TurnAllocationError![]u8 {
        if (self.started_at_ns != null or self.allocation != null) return error.Complete;
        self.started_at_ns = now_ns;
        const requested_transport = [_]u8{ 17, 0, 0, 0 };
        var integrity = [_]u8{0} ** protocol.stun_integrity_tag_bytes;
        const attributes = [_]protocol.StunAttribute{ .{ .kind = 0x0019, .value = requested_transport[0..] }, .{ .kind = 0x0006, .value = self.config.credentials.username }, .{ .kind = 0x0014, .value = self.config.credentials.realm }, .{ .kind = 0x0015, .value = self.config.credentials.nonce }, .{ .kind = 0x001c, .value = integrity[0..] } };
        const encoded = try protocol.encode_stun_message(.{ .method = 3, .class = .request, .transaction_id = self.transaction_id }, attributes[0..], output);
        const value_offset = integrityValueOffset(encoded) orelse return error.InvalidConfiguration;
        const expected = try protocol.stun_long_term_integrity(self.config.credentials, encoded[0..value_offset]);
        @memcpy(encoded[value_offset..][0..protocol.stun_integrity_tag_bytes], &expected);
        return encoded;
    }

    pub fn receive(self: *TurnAllocationClient, now_ns: core.TimeNs, header: protocol.StunHeader, attributes: []const protocol.StunAttribute) TurnAllocationError!TurnAllocation {
        const started = self.started_at_ns orelse return error.NotStarted;
        if (self.allocation != null) return error.Complete;
        if (header.method != 3 or !std.mem.eql(u8, &header.transaction_id, &self.transaction_id)) return error.UnexpectedResponse;
        if (header.class == .error_response) return error.AllocationRejected;
        if (header.class != .success_response) return error.UnexpectedResponse;
        var relay: ?protocol.StunAddress = null;
        var lifetime: ?u32 = null;
        for (attributes) |attribute| switch (attribute.kind) {
            0x0016 => relay = protocol.decode_xor_address(attribute.value, header.transaction_id) catch return error.MissingRelayAddress,
            0x000d => {
                if (attribute.value.len != 4) return error.InvalidLifetime;
                const bytes: *const [4]u8 = @ptrCast(attribute.value.ptr);
                lifetime = @import("std").mem.readInt(u32, bytes, .big);
            },
            else => {},
        };
        const address = relay orelse return error.MissingRelayAddress;
        const seconds = lifetime orelse return error.MissingLifetime;
        if (seconds == 0) return error.InvalidLifetime;
        const expires_at_ns = started +| @as(core.TimeNs, seconds) *| @as(core.TimeNs, @import("std").time.ns_per_s);
        const allocation = TurnAllocation{ .relay = address, .expires_at_ns = expires_at_ns };
        _ = now_ns;
        self.allocation = allocation;
        return allocation;
    }

    pub fn receive_frame(self: *TurnAllocationClient, now_ns: core.TimeNs, frame: []const u8, attributes: []protocol.StunAttribute) TurnAllocationError!TurnAllocation {
        const decoded = try protocol.decode_stun_message(frame, attributes);
        try verifyResponseIntegrity(self.config.credentials, frame);
        return self.receive(now_ns, decoded.header, attributes[0..decoded.count]);
    }
};

fn integrityValueOffset(frame: []const u8) ?usize {
    var offset: usize = protocol.stun_header_bytes;
    while (offset + 4 <= frame.len) {
        const kind = std.mem.readInt(u16, frame[offset..][0..2], .big);
        const value_len: usize = std.mem.readInt(u16, frame[offset + 2 ..][0..2], .big);
        const value_offset = offset + 4;
        if (kind == 0x001c) return if (value_len == protocol.stun_integrity_tag_bytes and value_offset + value_len <= frame.len) value_offset else null;
        offset = value_offset + std.mem.alignForward(usize, value_len, 4);
    }
    return null;
}

fn verifyResponseIntegrity(credentials: protocol.StunLongTermCredentials, frame: []const u8) TurnAllocationError!void {
    const value_offset = integrityValueOffset(frame) orelse return error.IntegrityMismatch;
    var received: [protocol.stun_integrity_tag_bytes]u8 = undefined;
    @memcpy(&received, frame[value_offset..][0..protocol.stun_integrity_tag_bytes]);
    var header = frame[0..protocol.stun_header_bytes].*;
    std.mem.writeInt(u16, header[2..4], @intCast(value_offset + protocol.stun_integrity_tag_bytes - protocol.stun_header_bytes), .big);
    var key = try longTermKey(credentials);
    defer std.crypto.secureZero(u8, &key);
    var context = std.crypto.auth.hmac.sha2.HmacSha256.init(&key);
    context.update(&header);
    context.update(frame[protocol.stun_header_bytes..value_offset]);
    var expected: [protocol.stun_integrity_tag_bytes]u8 = undefined;
    context.final(&expected);
    defer std.crypto.secureZero(u8, &expected);
    return protocol.verify_stun_integrity(frame, expected, received);
}

fn longTermKey(credentials: protocol.StunLongTermCredentials) protocol.StunCredentialError![32]u8 {
    try protocol.validate_long_term_credentials(credentials);
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    digest.update(credentials.username);
    digest.update(":");
    digest.update(credentials.realm);
    digest.update(":");
    digest.update(credentials.password);
    var key: [32]u8 = undefined;
    digest.final(&key);
    return key;
}

fn encodeAllocationResponse(transaction_id: [12]u8, relay: protocol.StunAddress, lifetime_seconds: u32, credentials: protocol.StunLongTermCredentials, output: []u8) ![]u8 {
    var address: [20]u8 = undefined;
    var lifetime: [4]u8 = undefined;
    const relay_value = try protocol.encode_xor_address(relay, transaction_id, address[0..]);
    std.mem.writeInt(u32, lifetime[0..], lifetime_seconds, .big);
    var integrity = [_]u8{0} ** protocol.stun_integrity_tag_bytes;
    const attributes = [_]protocol.StunAttribute{ .{ .kind = 0x0016, .value = relay_value }, .{ .kind = 0x000d, .value = lifetime[0..] }, .{ .kind = 0x001c, .value = integrity[0..] } };
    const encoded = try protocol.encode_stun_message(.{ .method = 3, .class = .success_response, .transaction_id = transaction_id }, attributes[0..], output);
    const value_offset = integrityValueOffset(encoded) orelse return error.InvalidConfiguration;
    const expected = try protocol.stun_long_term_integrity(credentials, encoded[0..value_offset]);
    @memcpy(encoded[value_offset..][0..protocol.stun_integrity_tag_bytes], &expected);
    return encoded;
}

test "TURN allocations authenticate allocate requests and parse relay lifetimes" {
    const server = transport.Ipv4Address{ .octets = .{ 1, 1, 1, 1 }, .port = 3478 };
    const credentials = protocol.StunLongTermCredentials{ .username = "u", .password = "p", .realm = "r", .nonce = "n", .algorithm = .sha256 };
    var client = try TurnAllocationClient.init(.{ .server = server, .credentials = credentials, .requested_lifetime_seconds = 60 }, .{4} ** 12);
    var request: [128]u8 = undefined;
    const encoded_request = try client.begin(10, request[0..]);
    var request_attributes: [5]protocol.StunAttribute = undefined;
    try @import("std").testing.expectEqual(@as(usize, 5), (try protocol.decode_stun_message(encoded_request, request_attributes[0..])).count);
    try verifyResponseIntegrity(credentials, encoded_request);
    var response: [128]u8 = undefined;
    const encoded_response = try encodeAllocationResponse(.{4} ** 12, .{ .ipv4 = .{ .octets = .{ 2, 2, 2, 2 }, .port = 5000 } }, 60, credentials, response[0..]);
    var response_attributes: [3]protocol.StunAttribute = undefined;
    const allocation = try client.receive_frame(11, encoded_response, response_attributes[0..]);
    try @import("std").testing.expectEqual(protocol.StunAddress{ .ipv4 = .{ .octets = .{ 2, 2, 2, 2 }, .port = 5000 } }, allocation.relay);
    try @import("std").testing.expect(allocation.expires_at_ns > 10);
}

test "TURN allocations reject invalid credentials and incomplete responses" {
    const server = transport.Ipv4Address{ .octets = .{ 1, 1, 1, 1 }, .port = 3478 };
    const credentials = protocol.StunLongTermCredentials{ .username = "u", .password = "p", .realm = "r", .nonce = "n", .algorithm = .sha256 };
    try @import("std").testing.expectError(error.InvalidConfiguration, TurnAllocationClient.init(.{ .server = server, .credentials = credentials, .requested_lifetime_seconds = 0 }, .{0} ** 12));
    var client = try TurnAllocationClient.init(.{ .server = server, .credentials = credentials, .requested_lifetime_seconds = 1 }, .{0} ** 12);
    var request: [128]u8 = undefined;
    _ = try client.begin(0, request[0..]);
    try @import("std").testing.expectError(error.MissingRelayAddress, client.receive(0, .{ .method = 3, .class = .success_response, .transaction_id = .{0} ** 12 }, &.{}));
    try @import("std").testing.expectError(error.AllocationRejected, client.receive(0, .{ .method = 3, .class = .error_response, .transaction_id = .{0} ** 12 }, &.{}));
}
