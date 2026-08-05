const std = @import("std");
const core = @import("minna-san-core");
const protocol = @import("minna-san-protocol");
const transport = @import("minna-san-transport");

pub const UdpStunBindingError = error{ InvalidConfiguration, NotStarted, AlreadyComplete, Timeout, UnexpectedResponse, MissingMappedAddress, InvalidAlternateServer, AlternateServerLimit };
pub const UdpStunBindingConfig = struct { server: transport.Ipv4Address, initial_rto_ns: core.TimeNs, maximum_retransmissions: usize, maximum_alternate_servers: usize = 1 };
pub const UdpStunBindingSend = struct { server: transport.Ipv4Address, transaction_id: [12]u8, retransmission: bool };
pub const UdpStunBindingResult = union(enum) { mapped: protocol.StunAddress, alternate: transport.Ipv4Address };

pub const UdpStunBindingClient = struct {
    config: UdpStunBindingConfig,
    server: transport.Ipv4Address,
    transaction_id: [12]u8,
    attempts: usize = 0,
    alternates: usize = 0,
    next_retry_ns: ?core.TimeNs = null,
    complete: bool = false,

    pub fn init(config: UdpStunBindingConfig, transaction_id: [12]u8) UdpStunBindingError!UdpStunBindingClient {
        if (config.server.port == 0 or config.initial_rto_ns == 0 or config.maximum_retransmissions == 0) return error.InvalidConfiguration;
        return .{ .config = config, .server = config.server, .transaction_id = transaction_id };
    }

    pub fn begin(self: *UdpStunBindingClient, now_ns: core.TimeNs) UdpStunBindingError!UdpStunBindingSend {
        if (self.next_retry_ns != null) return error.AlreadyComplete;
        self.attempts = 1;
        self.next_retry_ns = now_ns +| self.config.initial_rto_ns;
        return .{ .server = self.server, .transaction_id = self.transaction_id, .retransmission = false };
    }

    pub fn poll(self: *UdpStunBindingClient, now_ns: core.TimeNs) UdpStunBindingError!?UdpStunBindingSend {
        const retry_at = self.next_retry_ns orelse return error.NotStarted;
        if (self.complete) return error.AlreadyComplete;
        if (now_ns < retry_at) return null;
        if (self.attempts >= self.config.maximum_retransmissions) return error.Timeout;
        const exponent: u6 = @intCast(@min(self.attempts, @as(usize, 63)));
        const delay = self.config.initial_rto_ns << exponent;
        self.attempts += 1;
        self.next_retry_ns = now_ns +| delay;
        return .{ .server = self.server, .transaction_id = self.transaction_id, .retransmission = true };
    }

    pub fn receive(self: *UdpStunBindingClient, header: protocol.StunHeader, attributes: []const protocol.StunAttribute) UdpStunBindingError!UdpStunBindingResult {
        if (self.next_retry_ns == null) return error.NotStarted;
        if (self.complete or !std.mem.eql(u8, &header.transaction_id, &self.transaction_id)) return error.UnexpectedResponse;
        switch (header.class) {
            .success_response => {
                for (attributes) |attribute| if (attribute.kind == 0x0020) {
                    const mapped = protocol.decode_xor_address(attribute.value, header.transaction_id) catch return error.MissingMappedAddress;
                    self.complete = true;
                    return .{ .mapped = mapped };
                };
                return error.MissingMappedAddress;
            },
            .error_response => {
                for (attributes) |attribute| if (attribute.kind == 0x0009) {
                    const code = protocol.decode_error_code(attribute.value) catch return error.UnexpectedResponse;
                    if (code.code != 300) return error.UnexpectedResponse;
                };
                for (attributes) |attribute| if (attribute.kind == 0x8023) {
                    if (self.alternates == self.config.maximum_alternate_servers) return error.AlternateServerLimit;
                    const alternate = decode_address(attribute.value) catch return error.InvalidAlternateServer;
                    self.server = alternate;
                    self.alternates += 1;
                    self.attempts = 0;
                    self.next_retry_ns = null;
                    return .{ .alternate = alternate };
                };
                return error.InvalidAlternateServer;
            },
            else => return error.UnexpectedResponse,
        }
    }
};

fn decode_address(input: []const u8) !transport.Ipv4Address {
    if (input.len != 8 or input[0] != 0 or input[1] != 1) return error.Invalid;
    return .{ .octets = .{ input[4], input[5], input[6], input[7] }, .port = @import("std").mem.readInt(u16, input[2..4], .big) };
}

test "UDP STUN binding retransmits maps and follows bounded alternates" {
    const server = transport.Ipv4Address{ .octets = .{ 1, 1, 1, 1 }, .port = 3478 };
    var client = try UdpStunBindingClient.init(.{ .server = server, .initial_rto_ns = 10, .maximum_retransmissions = 2 }, .{0} ** 12);
    try @import("std").testing.expect(!(try client.begin(0)).retransmission);
    try @import("std").testing.expect((try client.poll(9)) == null);
    try @import("std").testing.expect((try client.poll(10)).?.retransmission);
    var value: [8]u8 = undefined;
    const mapped = try protocol.encode_xor_address(.{ .ipv4 = .{ .octets = .{ 2, 2, 2, 2 }, .port = 5000 } }, .{0} ** 12, value[0..]);
    const result = try client.receive(.{ .method = 1, .class = .success_response, .transaction_id = .{0} ** 12 }, &.{.{ .kind = 0x0020, .value = mapped }});
    try @import("std").testing.expectEqual(protocol.StunAddress{ .ipv4 = .{ .octets = .{ 2, 2, 2, 2 }, .port = 5000 } }, result.mapped);
}

test "UDP STUN binding rejects timeout and malformed alternate responses" {
    const server = transport.Ipv4Address{ .octets = .{ 1, 1, 1, 1 }, .port = 3478 };
    var client = try UdpStunBindingClient.init(.{ .server = server, .initial_rto_ns = 1, .maximum_retransmissions = 1 }, .{1} ** 12);
    _ = try client.begin(0);
    try @import("std").testing.expectError(error.Timeout, client.poll(1));
    var other = try UdpStunBindingClient.init(.{ .server = server, .initial_rto_ns = 1, .maximum_retransmissions = 1 }, .{2} ** 12);
    _ = try other.begin(0);
    try @import("std").testing.expectError(error.InvalidAlternateServer, other.receive(.{ .method = 1, .class = .error_response, .transaction_id = .{2} ** 12 }, &.{.{ .kind = 0x0009, .value = &.{ 0, 0, 3, 0 } }}));
    var alternate: [8]u8 = .{ 0, 1, 0, 2, 9, 9, 9, 9 };
    const result = try other.receive(.{ .method = 1, .class = .error_response, .transaction_id = .{2} ** 12 }, &.{ .{ .kind = 0x0009, .value = &.{ 0, 0, 3, 0 } }, .{ .kind = 0x8023, .value = alternate[0..] } });
    try @import("std").testing.expectEqual(UdpStunBindingResult{ .alternate = .{ .octets = .{ 9, 9, 9, 9 }, .port = 2 } }, result);
    try @import("std").testing.expectEqual(@as(u16, 2), (try other.begin(1)).server.port);
}
