const up = @import("unpolished-peas");
const guest = @import("guest_credentials.zig");

pub const GuestToken = guest.Token;
pub const GuestCredentials = guest.Credentials;
pub const GuestCredentialStore = guest.Store;

pub const Endpoint = struct {
    host: []const u8,
    port: u16,

    pub fn local() Endpoint {
        return .{ .host = "127.0.0.1", .port = 48080 };
    }

    pub fn isUsable(self: Endpoint) bool {
        return self.host.len != 0 and self.port != 0;
    }
};

pub const ClientTarget = struct {
    endpoint: Endpoint,

    pub fn init(endpoint: Endpoint) error{InvalidServiceEndpoint}!ClientTarget {
        if (!endpoint.isUsable()) return error.InvalidServiceEndpoint;
        return .{ .endpoint = endpoint };
    }
};

pub const networking = struct {
    pub const Peer = up.NetPeer;
    pub const Transport = up.NetTransport;
    pub const Received = up.NetReceived;
    pub const LoopbackTransport = up.LoopbackTransport;
    pub const UdpTransport = up.UdpTransport;
    pub const HandshakeClient = up.HandshakeClient;
    pub const HandshakeServer = up.HandshakeServer;
    pub const Channel = up.NetChannel;
};

test "services module imports only core contracts" {
    const transport = networking.Transport;
    _ = transport;
}

test "engine client can target the local service runtime" {
    const target = try ClientTarget.init(Endpoint.local());
    try @import("std").testing.expectEqualStrings("127.0.0.1", target.endpoint.host);
    try @import("std").testing.expectEqual(@as(u16, 48080), target.endpoint.port);
}
