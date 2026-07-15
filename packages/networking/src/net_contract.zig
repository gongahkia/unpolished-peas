const std = @import("std");
const channel = @import("net_channel.zig");
const transport = @import("net_transport.zig");

pub const Mode = enum {
    authoritative,
    peer_to_peer,
};

pub const Role = enum {
    client,
    dedicated_host,
    listen_host,
    peer,
};

pub const Reliability = channel.Mode;

pub const Error = error{
    InvalidNetworkContract,
    InvalidNetworkIdentity,
    InvalidNetworkPeer,
    InvalidNetworkRole,
    InvalidNetworkSession,
    NetworkSessionExpired,
};

pub const Identity = struct {
    value: u128,

    pub fn init(value: u128) Error!Identity {
        if (value == 0) return error.InvalidNetworkIdentity;
        return .{ .value = value };
    }
};

pub const Session = struct {
    id: u128,
    identity: Identity,
    issued_at_ms: u64,
    expires_at_ms: u64,

    pub fn validateAt(self: Session, now_ms: u64) Error!void {
        _ = try Identity.init(self.identity.value);
        if (self.id == 0 or self.expires_at_ms <= self.issued_at_ms) return error.InvalidNetworkSession;
        if (now_ms >= self.expires_at_ms) return error.NetworkSessionExpired;
    }
};

pub const Config = struct {
    mode: Mode,
    role: Role,
    protocol_version: u16 = 1,
    max_connections: u16 = 16,
    default_reliability: Reliability = .reliable_ordered,

    pub fn validate(self: Config) Error!void {
        if (self.protocol_version == 0 or self.max_connections == 0 or self.max_connections > 64) return error.InvalidNetworkContract;
        switch (self.mode) {
            .authoritative => switch (self.role) {
                .client, .dedicated_host, .listen_host => {},
                .peer => return error.InvalidNetworkRole,
            },
            .peer_to_peer => if (self.role != .peer) return error.InvalidNetworkRole,
        }
    }
};

pub const Connection = struct {
    contract: Config,
    session: Session,
    peer: transport.Peer,

    pub fn init(contract: Config, session: Session, peer: transport.Peer, now_ms: u64) Error!Connection {
        try contract.validate();
        try session.validateAt(now_ms);
        if (peer.id == 0) return error.InvalidNetworkPeer;
        return .{ .contract = contract, .session = session, .peer = peer };
    }
};

test "loopback conformance supports authoritative and peer-to-peer contracts" {
    const configs = [_]Config{
        .{ .mode = .authoritative, .role = .listen_host },
        .{ .mode = .peer_to_peer, .role = .peer, .default_reliability = .unreliable_sequenced },
    };
    for (configs) |config| {
        const identity = try Identity.init(1);
        const session = Session{ .id = 1, .identity = identity, .issued_at_ms = 0, .expires_at_ms = 10 };
        var first = transport.Loopback.init(std.testing.allocator, .{ .id = 1 });
        defer first.deinit();
        var second = transport.Loopback.init(std.testing.allocator, .{ .id = 2 });
        defer second.deinit();
        transport.Loopback.pair(&first, &second);
        const connection = try Connection.init(config, session, .{ .id = 2 }, 1);
        var sender = try channel.Channel.init(std.testing.allocator, connection.peer, .{});
        defer sender.deinit();
        var receiver = try channel.Channel.init(std.testing.allocator, .{ .id = 1 }, .{});
        defer receiver.deinit();
        switch (config.default_reliability) {
            .reliable_ordered => try sender.sendReliable(first.transport(), @tagName(config.mode)),
            .unreliable_sequenced => try sender.sendUnreliable(first.transport(), @tagName(config.mode)),
        }
        try receiver.poll(second.transport());
        var received = receiver.receive() orelse return error.TestExpectedEqual;
        defer received.deinit(std.testing.allocator);
        try std.testing.expectEqual(config.default_reliability, received.mode);
        try std.testing.expectEqualStrings(@tagName(config.mode), received.payload);
    }
}

test "network contract rejects incompatible role and bounds" {
    try std.testing.expectError(error.InvalidNetworkRole, (Config{ .mode = .authoritative, .role = .peer }).validate());
    try std.testing.expectError(error.InvalidNetworkRole, (Config{ .mode = .peer_to_peer, .role = .client }).validate());
    try std.testing.expectError(error.InvalidNetworkContract, (Config{ .mode = .authoritative, .role = .client, .max_connections = 65 }).validate());
    try std.testing.expectError(error.InvalidNetworkIdentity, Identity.init(0));
    const session = Session{ .id = 1, .identity = try Identity.init(1), .issued_at_ms = 0, .expires_at_ms = 1 };
    try std.testing.expectError(error.NetworkSessionExpired, session.validateAt(1));
}
