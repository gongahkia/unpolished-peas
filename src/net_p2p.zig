const std = @import("std");
const channel = @import("net_channel.zig");
const contract = @import("net_contract.zig");
const transport = @import("net_transport.zig");

pub const control_bytes: usize = 60;
pub const State = enum { idle, negotiating, connected, failed, closed };
pub const Failure = enum { authentication_failed, incompatible_version, malformed_control, malformed_data, negotiation_timeout, session_expired, unexpected_peer, unexpected_transition };
pub const Route = enum { direct, relay };
const ControlKind = enum(u8) { offer = 1, accept = 2 };
const control_magic: u8 = 0xa1;

pub const Config = struct {
    contract: contract.Config = .{ .mode = .peer_to_peer, .role = .peer },
    local_identity: contract.Identity,
    remote_identity: contract.Identity,
    session_id: u128,
    authentication_token: u64,
    issued_at_ms: u64 = 0,
    expires_at_ms: u64,
    peer: transport.Peer,
    route: Route = .direct,
    negotiation_timeout_ms: u64 = 5_000,
    channel: channel.Config = .{},
};

pub const Control = struct {
    kind: ControlKind,
    protocol_version: u16,
    session_id: u128,
    sender: u128,
    recipient: u128,
    authentication_token: u64,
};

pub const Peer = struct { // owns the shared data channel; call deinit once.
    allocator: std.mem.Allocator,
    config: Config,
    state: State = .idle,
    failure: ?Failure = null,
    started_at_ms: ?u64 = null,
    data: channel.Channel,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Peer {
        try validateConfig(config);
        return .{ .allocator = allocator, .config = config, .data = try channel.Channel.init(allocator, config.peer, config.channel) };
    }

    pub fn deinit(self: *Peer) void {
        self.data.deinit();
        self.* = undefined;
    }

    pub fn begin(self: *Peer, net: transport.Transport) !void {
        if (self.state != .idle) return error.InvalidPeerState;
        try self.validateSession(net.now());
        self.state = .negotiating;
        self.started_at_ms = net.now();
        try self.sendControl(net, .offer);
    }

    pub fn poll(self: *Peer, net: transport.Transport) !void {
        if (self.state == .closed) return error.PeerClosed;
        if (self.state == .failed) return error.PeerFailed;
        try net.poll();
        while (net.receive()) |received| {
            var packet = received;
            defer packet.deinit(self.allocator);
            if (packet.from.id != self.config.peer.id) return self.fail(.unexpected_peer, error.UnexpectedPeer);
            if (packet.bytes.len > channel.header_bytes + channel.max_payload_bytes) return self.fail(.malformed_data, error.MalformedChannelPacket);
            if (packet.bytes.len > 0 and packet.bytes[0] == control_magic) {
                try self.handleControl(net, packet.bytes);
            } else {
                self.data.receivePacket(net, packet) catch |err| return self.fail(.malformed_data, err);
            }
        }
        if (self.state == .negotiating) {
            try self.validateSession(net.now());
            const started = self.started_at_ms orelse return self.fail(.unexpected_transition, error.InvalidPeerState);
            if (net.now() < started or net.now() - started >= self.config.negotiation_timeout_ms) return self.fail(.negotiation_timeout, error.NegotiationTimedOut);
        }
        self.data.tick(net) catch |err| return self.fail(.malformed_data, err);
    }

    pub fn sendReliable(self: *Peer, net: transport.Transport, payload: []const u8) !void {
        try self.requireConnected();
        try self.data.sendReliable(net, payload);
    }

    pub fn sendUnreliable(self: *Peer, net: transport.Transport, payload: []const u8) !void {
        try self.requireConnected();
        try self.data.sendUnreliable(net, payload);
    }

    pub fn receive(self: *Peer) ?channel.Message {
        return self.data.receive();
    }

    pub fn close(self: *Peer) void {
        if (self.state != .failed) self.state = .closed;
    }

    fn handleControl(self: *Peer, net: transport.Transport, bytes: []const u8) !void {
        const control = decodeControl(bytes) catch |err| return self.fail(.malformed_control, err);
        if (control.protocol_version != self.config.contract.protocol_version) return self.fail(.incompatible_version, error.IncompatiblePeerVersion);
        if (control.session_id != self.config.session_id or control.sender != self.config.remote_identity.value or control.recipient != self.config.local_identity.value or control.authentication_token != self.config.authentication_token) return self.fail(.authentication_failed, error.PeerAuthenticationFailed);
        try self.validateSession(net.now());
        switch (control.kind) {
            .offer => switch (self.state) {
                .idle => {
                    self.state = .negotiating;
                    self.started_at_ms = net.now();
                    try self.sendControl(net, .accept);
                },
                .negotiating, .connected => try self.sendControl(net, .accept),
                .failed, .closed => return self.fail(.unexpected_transition, error.InvalidPeerState),
            },
            .accept => if (self.state == .negotiating) {
                self.state = .connected;
                self.started_at_ms = null;
            } else return self.fail(.unexpected_transition, error.InvalidPeerState),
        }
    }

    fn sendControl(self: *Peer, net: transport.Transport, kind: ControlKind) !void {
        var bytes: [control_bytes]u8 = undefined;
        try net.send(self.config.peer, try encodeControl(&bytes, .{ .kind = kind, .protocol_version = self.config.contract.protocol_version, .session_id = self.config.session_id, .sender = self.config.local_identity.value, .recipient = self.config.remote_identity.value, .authentication_token = self.config.authentication_token }));
    }

    fn validateSession(self: *Peer, now_ms: u64) !void {
        if (now_ms < self.config.issued_at_ms or now_ms >= self.config.expires_at_ms) return self.fail(.session_expired, error.PeerSessionExpired);
    }

    fn requireConnected(self: *const Peer) !void {
        if (self.state != .connected) return error.PeerNotConnected;
    }

    fn fail(self: *Peer, reason: Failure, err: anyerror) anyerror {
        self.state = .failed;
        self.failure = reason;
        return err;
    }
};

pub fn encodeControl(destination: []u8, control: Control) ![]u8 {
    if (destination.len < control_bytes) return error.BufferTooSmall;
    if (control.protocol_version == 0 or control.session_id == 0 or control.sender == 0 or control.recipient == 0 or control.sender == control.recipient or control.authentication_token == 0) return error.InvalidPeerControl;
    destination[0] = control_magic;
    destination[1] = @intFromEnum(control.kind);
    std.mem.writeInt(u16, destination[2..4], control.protocol_version, .little);
    std.mem.writeInt(u128, destination[4..20], control.session_id, .little);
    std.mem.writeInt(u128, destination[20..36], control.sender, .little);
    std.mem.writeInt(u128, destination[36..52], control.recipient, .little);
    std.mem.writeInt(u64, destination[52..60], control.authentication_token, .little);
    return destination[0..control_bytes];
}

pub fn decodeControl(bytes: []const u8) !Control {
    if (bytes.len != control_bytes or bytes[0] != control_magic) return error.MalformedPeerControl;
    const control = Control{ .kind = std.meta.intToEnum(ControlKind, bytes[1]) catch return error.MalformedPeerControl, .protocol_version = std.mem.readInt(u16, bytes[2..4], .little), .session_id = std.mem.readInt(u128, bytes[4..20], .little), .sender = std.mem.readInt(u128, bytes[20..36], .little), .recipient = std.mem.readInt(u128, bytes[36..52], .little), .authentication_token = std.mem.readInt(u64, bytes[52..60], .little) };
    var encoded: [control_bytes]u8 = undefined;
    _ = encodeControl(&encoded, control) catch return error.MalformedPeerControl;
    return control;
}

pub fn fuzzState(allocator: std.mem.Allocator, input: []const u8) void {
    var first_endpoint = transport.Loopback.init(allocator, .{ .id = 1 });
    defer first_endpoint.deinit();
    var second_endpoint = transport.Loopback.init(allocator, .{ .id = 2 });
    defer second_endpoint.deinit();
    transport.Loopback.pair(&first_endpoint, &second_endpoint);
    const local = contract.Identity.init(11) catch return;
    const remote = contract.Identity.init(22) catch return;
    var peer = Peer.init(allocator, .{ .local_identity = local, .remote_identity = remote, .session_id = 33, .authentication_token = 44, .expires_at_ms = 1_000, .peer = .{ .id = 1 } }) catch return;
    defer peer.deinit();
    const bounded = input[0..@min(input.len, channel.header_bytes + channel.max_payload_bytes)];
    first_endpoint.transport().send(.{ .id = 2 }, bounded) catch return;
    _ = peer.poll(second_endpoint.transport()) catch {};
}

fn validateConfig(config: Config) !void {
    try config.contract.validate();
    if (config.contract.mode != .peer_to_peer or config.contract.role != .peer or config.local_identity.value == config.remote_identity.value or config.session_id == 0 or config.authentication_token == 0 or config.peer.id == 0 or config.negotiation_timeout_ms == 0 or config.expires_at_ms <= config.issued_at_ms) return error.InvalidPeerConfig;
}

const Pair = struct {
    first_endpoint: transport.Loopback = undefined,
    second_endpoint: transport.Loopback = undefined,
    first: Peer = undefined,
    second: Peer = undefined,

    fn init(self: *Pair, allocator: std.mem.Allocator, route: Route) !void {
        self.first_endpoint = transport.Loopback.init(allocator, .{ .id = 1 });
        errdefer self.first_endpoint.deinit();
        self.second_endpoint = transport.Loopback.init(allocator, .{ .id = 2 });
        errdefer self.second_endpoint.deinit();
        transport.Loopback.pair(&self.first_endpoint, &self.second_endpoint);
        const first_identity = try contract.Identity.init(11);
        const second_identity = try contract.Identity.init(22);
        self.first = try Peer.init(allocator, .{ .local_identity = first_identity, .remote_identity = second_identity, .session_id = 33, .authentication_token = 44, .expires_at_ms = 1_000, .peer = .{ .id = 2 }, .route = route });
        errdefer self.first.deinit();
        self.second = try Peer.init(allocator, .{ .local_identity = second_identity, .remote_identity = first_identity, .session_id = 33, .authentication_token = 44, .expires_at_ms = 1_000, .peer = .{ .id = 1 }, .route = route });
    }

    fn deinit(self: *Pair) void {
        self.second.deinit();
        self.first.deinit();
        self.second_endpoint.deinit();
        self.first_endpoint.deinit();
    }
};

test "peer negotiation authenticates deterministic direct and relay channels" {
    for ([_]Route{ .direct, .relay }) |route| {
        var peers: Pair = undefined;
        try peers.init(std.testing.allocator, route);
        defer peers.deinit();
        try peers.first.begin(peers.first_endpoint.transport());
        try peers.second.begin(peers.second_endpoint.transport());
        try peers.first.poll(peers.first_endpoint.transport());
        try peers.second.poll(peers.second_endpoint.transport());
        try peers.first.poll(peers.first_endpoint.transport());
        try peers.second.poll(peers.second_endpoint.transport());
        try std.testing.expectEqual(State.connected, peers.first.state);
        try std.testing.expectEqual(State.connected, peers.second.state);
        try peers.first.sendReliable(peers.first_endpoint.transport(), "reliable");
        try peers.first.sendUnreliable(peers.first_endpoint.transport(), "sequenced");
        try peers.second.poll(peers.second_endpoint.transport());
        var reliable = peers.second.receive() orelse return error.TestExpectedEqual;
        defer reliable.deinit(std.testing.allocator);
        var sequenced = peers.second.receive() orelse return error.TestExpectedEqual;
        defer sequenced.deinit(std.testing.allocator);
        try std.testing.expectEqual(channel.Mode.reliable_ordered, reliable.mode);
        try std.testing.expectEqualStrings("reliable", reliable.payload);
        try std.testing.expectEqual(channel.Mode.unreliable_sequenced, sequenced.mode);
        try std.testing.expectEqualStrings("sequenced", sequenced.payload);
    }
}

test "peer negotiation rejects bounded malformed and unauthenticated control" {
    var peers: Pair = undefined;
    try peers.init(std.testing.allocator, .direct);
    defer peers.deinit();
    try peers.first_endpoint.transport().send(.{ .id = 2 }, &([_]u8{control_magic} ** (control_bytes + 1)));
    try std.testing.expectError(error.MalformedPeerControl, peers.second.poll(peers.second_endpoint.transport()));
    try std.testing.expectEqual(State.failed, peers.second.state);
    try std.testing.expectEqual(Failure.malformed_control, peers.second.failure.?);
    var retry: Pair = undefined;
    try retry.init(std.testing.allocator, .direct);
    defer retry.deinit();
    var forged: [control_bytes]u8 = undefined;
    try retry.first_endpoint.transport().send(.{ .id = 2 }, try encodeControl(&forged, .{ .kind = .offer, .protocol_version = 1, .session_id = 33, .sender = 11, .recipient = 22, .authentication_token = 99 }));
    try std.testing.expectError(error.PeerAuthenticationFailed, retry.second.poll(retry.second_endpoint.transport()));
    try std.testing.expectEqual(Failure.authentication_failed, retry.second.failure.?);
}

test "peer negotiation enters a defined timeout state" {
    var peers: Pair = undefined;
    try peers.init(std.testing.allocator, .direct);
    defer peers.deinit();
    peers.first.config.negotiation_timeout_ms = 10;
    try peers.first.begin(peers.first_endpoint.transport());
    peers.first_endpoint.advance(10);
    try std.testing.expectError(error.NegotiationTimedOut, peers.first.poll(peers.first_endpoint.transport()));
    try std.testing.expectEqual(State.failed, peers.first.state);
    try std.testing.expectEqual(Failure.negotiation_timeout, peers.first.failure.?);
}

test "peer state transition fuzz keeps failures bounded" {
    var seed: u64 = 7;
    var iteration: usize = 0;
    while (iteration < 128) : (iteration += 1) {
        var peers: Pair = undefined;
        try peers.init(std.testing.allocator, .direct);
        defer peers.deinit();
        var bytes: [control_bytes]u8 = undefined;
        for (&bytes) |*byte| {
            seed *%= 6_364_136_223_846_793_005;
            seed +%= 1;
            byte.* = @truncate(seed >> 32);
        }
        try peers.first_endpoint.transport().send(.{ .id = 2 }, &bytes);
        _ = peers.second.poll(peers.second_endpoint.transport()) catch {};
        try std.testing.expect(peers.second.state == .idle or peers.second.state == .negotiating or peers.second.state == .failed);
        try std.testing.expect(peers.second.data.outgoing.items.len <= peers.second.data.config.reliable_window);
    }
}
