const std = @import("std");
const core = @import("minna-san-core");
const protocol = @import("minna-san-protocol");
const topology = @import("minna-san-topology");
const transport = @import("minna-san-transport");
const channel_delivery = @import("channel_delivery.zig");
const direct_route = @import("direct_connectivity_route.zig");

pub const direct_candidate_signal_bytes: usize = 22;
pub const P2PSessionBootstrapError = protocol.PublicKeyAuthenticationError || protocol.SignedSignalingError || protocol.SecureDatagramHandshakeError || topology.NatCandidateError || channel_delivery.ChannelDeliveryError || direct_route.DirectConnectivityRouteError || error{ InvalidConfiguration, InvalidState, CandidateSignalExpected, InvalidCandidateSignal, MissingRemoteCandidate, HandshakeIncomplete };
pub const P2PSessionBootstrapConfig = struct {
    identity: protocol.PublicKeyIdentity,
    expected_peer_identity: [protocol.public_key_identity_bytes]u8,
    signaling: protocol.SignalingVerificationConfig,
    replay_entries: []protocol.SignalingReplayEntry,
    session_id: u64,
    role: protocol.PublicKeyRole,
    tie_breaker: u64,

    pub fn validate(self: P2PSessionBootstrapConfig) P2PSessionBootstrapError!void {
        if (self.session_id == 0 or self.tie_breaker == 0 or self.signaling.session_intent != self.session_id) return error.InvalidConfiguration;
        try self.signaling.validate();
        _ = try self.identity.public_key();
        _ = std.crypto.sign.Ed25519.PublicKey.fromBytes(self.expected_peer_identity) catch return error.InvalidConfiguration;
    }
};

pub const P2PChannel = struct {
    route: *direct_route.DirectConnectivityRoute,
    descriptor: channel_delivery.ChannelDescriptor,

    pub fn init(route: *direct_route.DirectConnectivityRoute, descriptor: channel_delivery.ChannelDescriptor) P2PSessionBootstrapError!P2PChannel {
        try descriptor.validate();
        return .{ .route = route, .descriptor = descriptor };
    }

    pub fn semantics(self: P2PChannel) channel_delivery.ChannelSemantics {
        return self.descriptor.semantics();
    }

    pub fn send(self: *P2PChannel, payload: []const u8, now_ns: core.TimeNs) P2PSessionBootstrapError!direct_route.DirectConnectivityRouteEvent {
        try self.descriptor.validate_payload(payload.len);
        return self.route.send(payload, now_ns);
    }

    pub fn poll(self: *P2PChannel, output: []u8, now_ns: core.TimeNs) P2PSessionBootstrapError!?direct_route.DirectConnectivityRouteEvent {
        return self.route.poll(output, now_ns);
    }
};

pub const P2PSessionBootstrap = struct {
    key_exchange: protocol.PublicKeyKeyExchange,
    expected_peer_identity: [protocol.public_key_identity_bytes]u8,
    signaling: protocol.SignalingVerificationConfig,
    replay: protocol.SignedSignalingReplayRegistry,
    tie_breaker: u64,
    key_material: ?[protocol.public_key_session_key_bytes]u8 = null,
    handshake: ?protocol.SecureDatagramHandshake = null,
    remote_candidate: ?topology.NatCandidate = null,

    pub fn init(config: P2PSessionBootstrapConfig) P2PSessionBootstrapError!P2PSessionBootstrap {
        try config.validate();
        return .{
            .key_exchange = protocol.PublicKeyKeyExchange.init(config.identity, config.session_id, config.role),
            .expected_peer_identity = config.expected_peer_identity,
            .signaling = config.signaling,
            .replay = protocol.SignedSignalingReplayRegistry.init(config.replay_entries),
            .tie_breaker = config.tie_breaker,
        };
    }

    pub fn deinit(self: *P2PSessionBootstrap) void {
        if (self.handshake) |*handshake| handshake.deinit();
        if (self.key_material) |*key_material| std.crypto.secureZero(u8, key_material);
        self.key_exchange.deinit();
        self.* = undefined;
    }

    pub fn localHello(self: P2PSessionBootstrap) P2PSessionBootstrapError!protocol.PublicKeyHello {
        return self.key_exchange.hello();
    }

    pub fn acceptPeerHello(self: *P2PSessionBootstrap, peer: protocol.PublicKeyHello) P2PSessionBootstrapError!void {
        if (self.key_material != null or self.handshake != null) return error.InvalidState;
        const key_material = try self.key_exchange.derive_session_key(self.expected_peer_identity, peer);
        self.key_material = key_material;
        self.handshake = try protocol.SecureDatagramHandshake.init(.{
            .role = switch (self.key_exchange.role) {
                .initiator => .initiator,
                .responder => .responder,
            },
            .session_id = self.key_exchange.session_id,
            .timeout_ns = 100,
        }, &key_material);
    }

    pub fn beginHandshake(self: *P2PSessionBootstrap, now_ns: core.TimeNs) P2PSessionBootstrapError!protocol.SecureDatagramHandshakeMessage {
        const handshake = if (self.handshake) |*value| value else return error.InvalidState;
        return handshake.begin(now_ns);
    }

    pub fn receiveHandshake(self: *P2PSessionBootstrap, message: protocol.SecureDatagramHandshakeMessage, now_ns: core.TimeNs) P2PSessionBootstrapError!?protocol.SecureDatagramHandshakeMessage {
        const handshake = if (self.handshake) |*value| value else return error.InvalidState;
        return handshake.receive(message, now_ns);
    }

    pub fn acceptCandidateSignal(self: *P2PSessionBootstrap, wire: []const u8, now_ns: core.TimeNs) P2PSessionBootstrapError!topology.NatCandidate {
        const message = try self.replay.verify_and_remember(self.signaling, wire, now_ns);
        if (message.kind != .candidate) return error.CandidateSignalExpected;
        const candidate = try decode_direct_candidate_signal(message.payload, now_ns);
        self.remote_candidate = candidate;
        return candidate;
    }

    pub fn openDirectRoute(self: *const P2PSessionBootstrap, local_candidate: topology.NatCandidate, local_address: transport.Ipv4Address, now_ns: core.TimeNs) P2PSessionBootstrapError!direct_route.DirectConnectivityRoute {
        const remote_candidate = self.remote_candidate orelse return error.MissingRemoteCandidate;
        const handshake = self.handshake orelse return error.HandshakeIncomplete;
        if (handshake.state != .authenticated) return error.HandshakeIncomplete;
        const key_material = self.key_material orelse return error.HandshakeIncomplete;
        var keys = try handshake.derivePacketKeys(&key_material);
        defer keys.clear();
        const send_key, const receive_key = switch (self.key_exchange.role) {
            .initiator => .{ keys.initiator_to_responder, keys.responder_to_initiator },
            .responder => .{ keys.responder_to_initiator, keys.initiator_to_responder },
        };
        return direct_route.DirectConnectivityRoute.init(.{
            .pair = .{ .local = local_candidate, .remote = remote_candidate, .priority = @min(local_candidate.priority, remote_candidate.priority), .state = .nominated },
            .local_address = local_address,
            .session_intent = self.signaling.session_intent,
            .role = switch (self.key_exchange.role) {
                .initiator => .controlling,
                .responder => .controlled,
            },
            .tie_breaker = self.tie_breaker,
            .send_key = send_key,
            .receive_key = receive_key,
        }, now_ns);
    }
};

pub fn encode_direct_candidate_signal(candidate: topology.NatCandidate, output: []u8) P2PSessionBootstrapError![]const u8 {
    if (candidate.kind == .relay or candidate.transport != .udp or candidate.credentials != null or candidate.expires_at_ns == 0 or candidate.priority == 0) return error.InvalidCandidateSignal;
    const address = switch (candidate.address) {
        .ipv4 => |value| value,
        .ipv6 => return error.InvalidCandidateSignal,
    };
    if (address.port == 0 or output.len < direct_candidate_signal_bytes) return error.InvalidCandidateSignal;
    output[0] = 1;
    output[1] = @intFromEnum(candidate.kind);
    output[2] = @intFromEnum(candidate.transport);
    output[3] = 0;
    std.mem.writeInt(u32, output[4..8], candidate.priority, .big);
    std.mem.writeInt(u64, output[8..16], candidate.expires_at_ns, .big);
    @memcpy(output[16..20], &address.octets);
    std.mem.writeInt(u16, output[20..22], address.port, .big);
    return output[0..direct_candidate_signal_bytes];
}

pub fn decode_direct_candidate_signal(input: []const u8, now_ns: core.TimeNs) P2PSessionBootstrapError!topology.NatCandidate {
    if (input.len != direct_candidate_signal_bytes or input[0] != 1 or input[3] != 0) return error.InvalidCandidateSignal;
    const kind = std.meta.intToEnum(topology.NatCandidateKind, input[1]) catch return error.InvalidCandidateSignal;
    const transport_kind = std.meta.intToEnum(topology.NatCandidateTransport, input[2]) catch return error.InvalidCandidateSignal;
    if (kind == .relay or transport_kind != .udp) return error.InvalidCandidateSignal;
    var octets: [4]u8 = undefined;
    @memcpy(&octets, input[16..20]);
    const candidate = topology.NatCandidate{
        .kind = kind,
        .transport = transport_kind,
        .address = .{ .ipv4 = .{ .octets = octets, .port = std.mem.readInt(u16, input[20..22], .big) } },
        .priority = std.mem.readInt(u32, input[4..8], .big),
        .expires_at_ns = std.mem.readInt(u64, input[8..16], .big),
    };
    topology.validate_nat_candidate(candidate, now_ns) catch return error.InvalidCandidateSignal;
    return candidate;
}

fn reserveLoopbackAddress() !transport.Ipv4Address {
    var socket = try transport.UdpSocket.init(.{});
    defer socket.close();
    try socket.bind(transport.Ipv4Address.wildcard(0));
    var native = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
    var length = native.getOsSockLen();
    try std.posix.getsockname(socket.socket.handle, &native.any, &length);
    return transport.Ipv4Address.parse("127.0.0.1", (try transport.Ipv4Address.from_native(native)).port);
}

fn hostCandidate(address: transport.Ipv4Address) topology.NatCandidate {
    return .{ .kind = .host, .transport = .udp, .address = .{ .ipv4 = address }, .priority = 10, .expires_at_ns = 100 };
}

fn pollWithRetry(channel: *P2PChannel, output: []u8, now_ns: core.TimeNs) !direct_route.DirectConnectivityRouteEvent {
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (try channel.poll(output, now_ns)) |event| return event;
        std.Thread.sleep(std.time.ns_per_ms);
    }
    return error.WouldBlock;
}

fn pollRouteWithRetry(route: *direct_route.DirectConnectivityRoute, output: []u8, now_ns: core.TimeNs) !direct_route.DirectConnectivityRouteEvent {
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (try route.poll(output, now_ns)) |event| return event;
        std.Thread.sleep(std.time.ns_per_ms);
    }
    return error.WouldBlock;
}

test "public P2P bootstrap composes signed candidates authenticated handshakes checks and channels without service signaling" {
    var initiator_identity = try protocol.PublicKeyIdentity.init([_]u8{1} ** std.crypto.sign.Ed25519.KeyPair.seed_length);
    defer initiator_identity.clear();
    var responder_identity = try protocol.PublicKeyIdentity.init([_]u8{2} ** std.crypto.sign.Ed25519.KeyPair.seed_length);
    defer responder_identity.clear();
    const initiator_credentials = protocol.SignalingApplicationCredentials{ .application_id = 4, .identity = initiator_identity };
    const responder_credentials = protocol.SignalingApplicationCredentials{ .application_id = 4, .identity = responder_identity };
    var initiator_replay: [2]protocol.SignalingReplayEntry = undefined;
    var responder_replay: [2]protocol.SignalingReplayEntry = undefined;
    var initiator = try P2PSessionBootstrap.init(.{ .identity = initiator_identity, .expected_peer_identity = try responder_identity.public_key(), .signaling = .{ .application_id = 4, .session_intent = 11, .expected_signer_identity = try responder_identity.public_key() }, .replay_entries = &initiator_replay, .session_id = 11, .role = .initiator, .tie_breaker = 2 });
    defer initiator.deinit();
    var responder = try P2PSessionBootstrap.init(.{ .identity = responder_identity, .expected_peer_identity = try initiator_identity.public_key(), .signaling = .{ .application_id = 4, .session_intent = 11, .expected_signer_identity = try initiator_identity.public_key() }, .replay_entries = &responder_replay, .session_id = 11, .role = .responder, .tie_breaker = 1 });
    defer responder.deinit();
    try initiator.acceptPeerHello(try responder.localHello());
    try responder.acceptPeerHello(try initiator.localHello());
    const hello = try initiator.beginHandshake(0);
    const challenge = (try responder.receiveHandshake(hello, 0)).?;
    const proof = (try initiator.receiveHandshake(challenge, 0)).?;
    const accept = (try responder.receiveHandshake(proof, 0)).?;
    try std.testing.expect((try initiator.receiveHandshake(accept, 0)) == null);
    const initiator_address = try reserveLoopbackAddress();
    const responder_address = try reserveLoopbackAddress();
    const initiator_candidate = hostCandidate(initiator_address);
    const responder_candidate = hostCandidate(responder_address);
    var candidate_payload: [direct_candidate_signal_bytes]u8 = undefined;
    var wire: [protocol.signed_signaling_header_bytes + direct_candidate_signal_bytes + protocol.signed_signaling_signature_bytes]u8 = undefined;
    const from_initiator = try protocol.encode_signed_signaling_message(initiator_credentials, .{ .kind = .candidate, .session_intent = 11, .expires_at_ns = 50, .nonce = 1, .payload = try encode_direct_candidate_signal(initiator_candidate, &candidate_payload) }, &wire);
    _ = try responder.acceptCandidateSignal(from_initiator, 1);
    const from_responder = try protocol.encode_signed_signaling_message(responder_credentials, .{ .kind = .candidate, .session_intent = 11, .expires_at_ns = 50, .nonce = 2, .payload = try encode_direct_candidate_signal(responder_candidate, &candidate_payload) }, &wire);
    _ = try initiator.acceptCandidateSignal(from_responder, 1);
    var initiator_route = try initiator.openDirectRoute(initiator_candidate, initiator_address, 1);
    defer initiator_route.deinit();
    var responder_route = try responder.openDirectRoute(responder_candidate, responder_address, 1);
    defer responder_route.deinit();
    _ = try initiator_route.sendCheck(false, 2);
    var raw: [32]u8 = undefined;
    _ = try pollRouteWithRetry(&responder_route, raw[0..], 2);
    _ = try responder_route.sendCheck(false, 2);
    _ = try pollRouteWithRetry(&initiator_route, raw[0..], 2);
    _ = try initiator_route.sendCheck(true, 3);
    _ = try pollRouteWithRetry(&responder_route, raw[0..], 3);
    const descriptor = channel_delivery.ChannelDescriptor{ .delivery = .ordered, .maximum_payload_bytes = 16 };
    var initiator_channel = try P2PChannel.init(&initiator_route, descriptor);
    var responder_channel = try P2PChannel.init(&responder_route, descriptor);
    try std.testing.expectEqual(channel_delivery.ChannelSemantics{ .reliable = true, .ordering = .ordered, .framing = .messages }, initiator_channel.semantics());
    try std.testing.expectEqual(direct_route.DirectConnectivityRouteEvent{ .sent = 21 }, try initiator_channel.send("public route", 4));
    try std.testing.expectEqualStrings("public route", (try pollWithRetry(&responder_channel, raw[0..], 4)).received);
}
