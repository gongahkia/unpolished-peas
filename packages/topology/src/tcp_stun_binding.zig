const std = @import("std");
const core = @import("minna-san-core");
const protocol = @import("minna-san-protocol");
const transport = @import("minna-san-transport");

pub const TcpStunBindingError = protocol.StunCodecError || protocol.StunCredentialError || error{ InvalidConfiguration, NotStarted, Complete, Timeout, UnexpectedResponse, MissingMappedAddress };
pub const TcpStunBindingConfig = struct { server: transport.Ipv4Address, timeout_ns: core.TimeNs, credentials: ?protocol.StunShortTermCredentials = null };
pub const TcpStunBindingResult = protocol.StunAddress;

pub const TcpStunBindingClient = struct {
    config: TcpStunBindingConfig,
    transaction_id: [12]u8,
    deadline_ns: ?core.TimeNs = null,
    complete: bool = false,

    pub fn init(config: TcpStunBindingConfig, transaction_id: [12]u8) TcpStunBindingError!TcpStunBindingClient {
        if (config.server.port == 0 or config.timeout_ns == 0) return error.InvalidConfiguration;
        if (config.credentials) |credentials| try protocol.validate_short_term_credentials(credentials);
        return .{ .config = config, .transaction_id = transaction_id };
    }

    pub fn begin(self: *TcpStunBindingClient, now_ns: core.TimeNs, output: []u8) TcpStunBindingError![]u8 {
        if (self.deadline_ns != null or self.complete) return error.Complete;
        self.deadline_ns = now_ns +| self.config.timeout_ns;
        return encodeBindingRequest(self.transaction_id, self.config.credentials, output);
    }

    pub fn poll(self: TcpStunBindingClient, now_ns: core.TimeNs) TcpStunBindingError!void {
        const deadline = self.deadline_ns orelse return error.NotStarted;
        if (self.complete) return error.Complete;
        if (now_ns >= deadline) return error.Timeout;
    }

    pub fn receive_frame(self: *TcpStunBindingClient, now_ns: core.TimeNs, frame: []const u8, attributes: []protocol.StunAttribute) TcpStunBindingError!TcpStunBindingResult {
        try self.poll(now_ns);
        const decoded = try protocol.decode_stun_message(frame, attributes);
        if (decoded.header.class != .success_response or !@import("std").mem.eql(u8, &decoded.header.transaction_id, &self.transaction_id)) return error.UnexpectedResponse;
        if (self.config.credentials) |credentials| try verifyResponseIntegrity(credentials, frame);
        for (attributes[0..decoded.count]) |attribute| if (attribute.kind == 0x0020) {
            const mapped = try protocol.decode_xor_address(attribute.value, decoded.header.transaction_id);
            self.complete = true;
            return mapped;
        };
        return error.MissingMappedAddress;
    }
};

fn encodeBindingRequest(transaction_id: [12]u8, credentials: ?protocol.StunShortTermCredentials, output: []u8) TcpStunBindingError![]u8 {
    const value = credentials orelse return protocol.encode_stun_message(.{ .method = 1, .class = .request, .transaction_id = transaction_id }, &.{}, output);
    var integrity = [_]u8{0} ** protocol.stun_integrity_tag_bytes;
    const attributes = [_]protocol.StunAttribute{ .{ .kind = 0x0006, .value = value.username }, .{ .kind = 0x001c, .value = integrity[0..] } };
    const encoded = try protocol.encode_stun_message(.{ .method = 1, .class = .request, .transaction_id = transaction_id }, attributes[0..], output);
    const integrity_offset = protocol.stun_header_bytes + 4 + std.mem.alignForward(usize, value.username.len, 4) + 4;
    const expected = try protocol.stun_short_term_integrity(value, encoded[0..integrity_offset]);
    @memcpy(encoded[integrity_offset..][0..protocol.stun_integrity_tag_bytes], &expected);
    return encoded;
}

fn verifyResponseIntegrity(credentials: protocol.StunShortTermCredentials, frame: []const u8) TcpStunBindingError!void {
    var offset: usize = protocol.stun_header_bytes;
    while (offset < frame.len) {
        const kind = std.mem.readInt(u16, frame[offset..][0..2], .big);
        const value_len: usize = std.mem.readInt(u16, frame[offset + 2 ..][0..2], .big);
        const value_offset = offset + 4;
        if (kind == 0x001c) {
            if (value_len != protocol.stun_integrity_tag_bytes) return error.IntegrityMismatch;
            var received: [protocol.stun_integrity_tag_bytes]u8 = undefined;
            @memcpy(&received, frame[value_offset..][0..protocol.stun_integrity_tag_bytes]);
            var header = frame[0..protocol.stun_header_bytes].*;
            std.mem.writeInt(u16, header[2..4], @intCast(value_offset + protocol.stun_integrity_tag_bytes - protocol.stun_header_bytes), .big);
            var context = std.crypto.auth.hmac.sha2.HmacSha256.init(credentials.password);
            context.update(&header);
            context.update(frame[protocol.stun_header_bytes..value_offset]);
            var expected: [protocol.stun_integrity_tag_bytes]u8 = undefined;
            context.final(&expected);
            defer std.crypto.secureZero(u8, &expected);
            return protocol.verify_stun_integrity(frame, expected, received);
        }
        offset += 4 + std.mem.alignForward(usize, value_len, 4);
    }
    return error.IntegrityMismatch;
}

fn encodeBindingResponse(transaction_id: [12]u8, mapped: protocol.StunAddress, credentials: protocol.StunShortTermCredentials, output: []u8) ![]u8 {
    var address: [20]u8 = undefined;
    const mapped_value = try protocol.encode_xor_address(mapped, transaction_id, address[0..]);
    var integrity = [_]u8{0} ** protocol.stun_integrity_tag_bytes;
    const attributes = [_]protocol.StunAttribute{ .{ .kind = 0x0020, .value = mapped_value }, .{ .kind = 0x001c, .value = integrity[0..] } };
    const encoded = try protocol.encode_stun_message(.{ .method = 1, .class = .success_response, .transaction_id = transaction_id }, attributes[0..], output);
    const integrity_offset = protocol.stun_header_bytes + 4 + std.mem.alignForward(usize, mapped_value.len, 4) + 4;
    const expected = try protocol.stun_short_term_integrity(credentials, encoded[0..integrity_offset]);
    @memcpy(encoded[integrity_offset..][0..protocol.stun_integrity_tag_bytes], &expected);
    return encoded;
}

test "TCP STUN binding frames authenticated requests and maps successful responses" {
    const server = transport.Ipv4Address{ .octets = .{ 1, 1, 1, 1 }, .port = 3478 };
    const credentials = protocol.StunShortTermCredentials{ .username = "u", .password = "p" };
    var client = try TcpStunBindingClient.init(.{ .server = server, .timeout_ns = 10, .credentials = credentials }, .{3} ** 12);
    var request: [64]u8 = undefined;
    const encoded_request = try client.begin(0, request[0..]);
    var request_attributes: [2]protocol.StunAttribute = undefined;
    const decoded_request = try protocol.decode_stun_message(encoded_request, request_attributes[0..]);
    try @import("std").testing.expectEqual(@as(usize, 2), decoded_request.count);
    try @import("std").testing.expectEqualStrings("u", request_attributes[0].value);
    try verifyResponseIntegrity(credentials, encoded_request);
    var frame: [128]u8 = undefined;
    const response = try encodeBindingResponse(.{3} ** 12, .{ .ipv4 = .{ .octets = .{ 2, 2, 2, 2 }, .port = 4000 } }, credentials, frame[0..]);
    var attributes: [2]protocol.StunAttribute = undefined;
    try @import("std").testing.expectEqual(protocol.StunAddress{ .ipv4 = .{ .octets = .{ 2, 2, 2, 2 }, .port = 4000 } }, try client.receive_frame(1, response, attributes[0..]));
}

test "TCP STUN binding rejects invalid credentials timeout and mismatched frames" {
    const server = transport.Ipv4Address{ .octets = .{ 1, 1, 1, 1 }, .port = 3478 };
    try @import("std").testing.expectError(error.InvalidCredential, TcpStunBindingClient.init(.{ .server = server, .timeout_ns = 1, .credentials = .{ .username = "", .password = "p" } }, .{0} ** 12));
    var client = try TcpStunBindingClient.init(.{ .server = server, .timeout_ns = 1 }, .{0} ** 12);
    var request: [20]u8 = undefined;
    _ = try client.begin(0, request[0..]);
    try @import("std").testing.expectError(error.Timeout, client.poll(1));
}
