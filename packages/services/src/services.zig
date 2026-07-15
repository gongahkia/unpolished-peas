const net = @import("unpolished-peas-networking");
const guest = @import("guest_credentials.zig");
const provider = @import("service_provider.zig");
const lobby = @import("service_lobby.zig");
const matchmaking = @import("service_matchmaking.zig");
const relay = @import("service_relay.zig");

pub const GuestToken = guest.Token;
pub const GuestCredentials = guest.Credentials;
pub const GuestCredentialStore = guest.Store;
pub const ServiceProvider = provider.Provider;
pub const ServiceProviderError = provider.Error;
pub const ServiceSessionRequest = provider.SessionRequest;
pub const ServiceSessionStatus = provider.SessionStatus;
pub const FakeServiceProvider = provider.FakeAdapter;
pub const LocalPostgresServiceProvider = provider.LocalPostgresAdapter;
pub const LobbyService = lobby.Service;
pub const LobbyConfig = lobby.Config;
pub const Lobby = lobby.Lobby;
pub const LobbyStatus = lobby.Status;
pub const LobbyInspectorState = lobby.InspectorState;
pub const MatchmakingService = matchmaking.Service;
pub const MatchmakingConfig = matchmaking.Config;
pub const MatchAssignment = matchmaking.Assignment;
pub const RelayService = relay.Service;
pub const RelayConfig = relay.Config;
pub const RelayBootstrap = relay.Bootstrap;
pub const RelayRoute = relay.Route;
pub const RelayLease = relay.Lease;

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
    pub const Peer = net.transport.Peer;
    pub const Transport = net.transport.Transport;
    pub const Received = net.transport.Received;
    pub const LoopbackTransport = net.transport.Loopback;
    pub const UdpTransport = net.transport.Udp;
    pub const HandshakeClient = net.handshake.Client;
    pub const HandshakeServer = net.handshake.Server;
    pub const Channel = net.channel.Channel;
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

test "services expose an SDL-free provider contract" {
    var fake = FakeServiceProvider{};
    const provider_contract = fake.provider();
    const credentials = try provider_contract.issueGuestSession(.{ .now_ms = 1, .lifetime_ms = 1 });
    try @import("std").testing.expectEqual(ServiceSessionStatus.active, try provider_contract.validateGuestSession(credentials.session));
}

test {
    _ = @import("service_integration.zig");
}
