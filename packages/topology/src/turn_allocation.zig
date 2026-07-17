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
        return protocol.encode_stun_message(.{ .method = 3, .class = .request, .transaction_id = self.transaction_id }, &.{ .{ .kind = 0x0019, .value = requested_transport[0..] }, .{ .kind = 0x0006, .value = self.config.credentials.username }, .{ .kind = 0x0014, .value = self.config.credentials.realm }, .{ .kind = 0x0015, .value = self.config.credentials.nonce } }, output);
    }

    pub fn receive(self: *TurnAllocationClient, now_ns: core.TimeNs, header: protocol.StunHeader, attributes: []const protocol.StunAttribute) TurnAllocationError!TurnAllocation {
        const started = self.started_at_ns orelse return error.NotStarted;
        if (self.allocation != null) return error.Complete;
        if (header.method != 3 or !@import("std").mem.eql(u8, &header.transaction_id, &self.transaction_id)) return error.UnexpectedResponse;
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
};

test "TURN allocations authenticate allocate requests and parse relay lifetimes" {
    const server = transport.Ipv4Address{ .octets = .{ 1, 1, 1, 1 }, .port = 3478 };
    const credentials = protocol.StunLongTermCredentials{ .username = "u", .password = "p", .realm = "r", .nonce = "n", .algorithm = .sha256 };
    var client = try TurnAllocationClient.init(.{ .server = server, .credentials = credentials, .requested_lifetime_seconds = 60 }, .{4} ** 12);
    var request: [128]u8 = undefined;
    _ = try client.begin(10, request[0..]);
    var address: [8]u8 = undefined;
    const relay = try protocol.encode_xor_address(.{ .ipv4 = .{ .octets = .{ 2, 2, 2, 2 }, .port = 5000 } }, .{4} ** 12, address[0..]);
    var lifetime: [4]u8 = undefined;
    @import("std").mem.writeInt(u32, lifetime[0..], 60, .big);
    const allocation = try client.receive(11, .{ .method = 3, .class = .success_response, .transaction_id = .{4} ** 12 }, &.{ .{ .kind = 0x0016, .value = relay }, .{ .kind = 0x000d, .value = lifetime[0..] } });
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
