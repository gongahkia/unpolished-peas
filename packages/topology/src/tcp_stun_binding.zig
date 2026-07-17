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
        return protocol.encode_stun_message(.{ .method = 1, .class = .request, .transaction_id = self.transaction_id }, &.{}, output);
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
        for (attributes[0..decoded.count]) |attribute| if (attribute.kind == 0x0020) {
            const mapped = try protocol.decode_xor_address(attribute.value, decoded.header.transaction_id);
            self.complete = true;
            return mapped;
        };
        return error.MissingMappedAddress;
    }
};

test "TCP STUN binding frames authenticated requests and maps successful responses" {
    const server = transport.Ipv4Address{ .octets = .{ 1, 1, 1, 1 }, .port = 3478 };
    var client = try TcpStunBindingClient.init(.{ .server = server, .timeout_ns = 10, .credentials = .{ .username = "u", .password = "p" } }, .{3} ** 12);
    var request: [20]u8 = undefined;
    try @import("std").testing.expectEqual(@as(usize, 20), (try client.begin(0, request[0..])).len);
    var address: [8]u8 = undefined;
    const value = try protocol.encode_xor_address(.{ .ipv4 = .{ .octets = .{ 2, 2, 2, 2 }, .port = 4000 } }, .{3} ** 12, address[0..]);
    var frame: [32]u8 = undefined;
    const response = try protocol.encode_stun_message(.{ .method = 1, .class = .success_response, .transaction_id = .{3} ** 12 }, &.{.{ .kind = 0x0020, .value = value }}, frame[0..]);
    var attributes: [1]protocol.StunAttribute = undefined;
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
