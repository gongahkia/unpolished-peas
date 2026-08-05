const std = @import("std");
const protocol = @import("minna-san-protocol");
const runtime = @import("minna-san-runtime");
const topology = @import("minna-san-topology");
const transport = @import("minna-san-transport");

pub const Role = enum { server, client };

const session_id: u64 = 73;
const application_id: u32 = 9;
const control_hello: u8 = 1;
const control_candidate: u8 = 2;
const control_handshake: u8 = 3;

pub fn parsePort(value: []const u8) !u16 {
    const port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidArgument;
    if (port == 0) return error.InvalidArgument;
    return port;
}

pub fn run(role: Role, local_port: u16, peer_port: u16) !void {
    const local = try transport.Ipv4Address.parse("127.0.0.1", local_port);
    const peer = try transport.Ipv4Address.parse("127.0.0.1", peer_port);
    var local_identity = try protocol.PublicKeyIdentity.init(identitySeed(role));
    defer local_identity.clear();
    var peer_identity = try protocol.PublicKeyIdentity.init(identitySeed(opposite(role)));
    defer peer_identity.clear();
    const expected_peer_identity = try peer_identity.public_key();
    const local_candidate = candidate(local);
    const credentials = protocol.SignalingApplicationCredentials{ .application_id = application_id, .identity = local_identity };
    var replay: [2]protocol.SignalingReplayEntry = undefined;
    var bootstrap = try runtime.P2PSessionBootstrap.init(.{
        .identity = local_identity,
        .expected_peer_identity = expected_peer_identity,
        .signaling = .{ .application_id = application_id, .session_intent = session_id, .expected_signer_identity = expected_peer_identity },
        .replay_entries = replay[0..],
        .session_id = session_id,
        .role = if (role == .client) .initiator else .responder,
        .tie_breaker = if (role == .client) 2 else 1,
    });
    defer bootstrap.deinit();
    try exchangeBootstrap(role, local, peer, local_candidate, credentials, &bootstrap);
    var route = try bootstrap.openDirectRoute(local_candidate, local, 1);
    defer route.deinit();
    try exchangePayload(role, &route);
    try std.fs.File.stdout().deprecatedWriter().writeAll("verified\n");
}

fn exchangeBootstrap(role: Role, local: transport.Ipv4Address, peer: transport.Ipv4Address, local_candidate: topology.NatCandidate, credentials: protocol.SignalingApplicationCredentials, bootstrap: *runtime.P2PSessionBootstrap) !void {
    var socket = try transport.UdpSocket.init(.{});
    defer socket.close();
    try socket.bind(local);
    if (role == .server) try std.fs.File.stdout().deprecatedWriter().writeAll("ready\n");
    var hello_wire: [protocol.public_key_hello_wire_bytes]u8 = undefined;
    const hello = try protocol.encode_public_key_hello(try bootstrap.localHello(), hello_wire[0..]);
    var candidate_payload: [runtime.direct_candidate_signal_bytes]u8 = undefined;
    var candidate_wire: [protocol.signed_signaling_header_bytes + runtime.direct_candidate_signal_bytes + protocol.signed_signaling_signature_bytes]u8 = undefined;
    const candidate_signal = try protocol.encode_signed_signaling_message(credentials, .{ .kind = .candidate, .session_intent = session_id, .expires_at_ns = 100, .nonce = if (role == .client) 1 else 2, .payload = try runtime.encode_direct_candidate_signal(local_candidate, candidate_payload[0..]) }, candidate_wire[0..]);
    var got_hello = false;
    var got_candidate = false;
    var started_handshake = false;
    var storage: [transport.max_ipv4_datagram_bytes]u8 = undefined;
    var attempts: usize = 0;
    while (attempts < 2_000) : (attempts += 1) {
        if (attempts % 10 == 0) {
            try sendControl(&socket, peer, control_hello, hello);
            try sendControl(&socket, peer, control_candidate, candidate_signal);
        }
        const received = socket.receive_from(storage[0..]) catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        if (!sameAddress(received.source, peer) or received.bytes.len < 2) return error.InvalidControlSource;
        const kind = received.bytes[0];
        const payload = received.bytes[1..];
        switch (kind) {
            control_hello => if (!got_hello) {
                try bootstrap.acceptPeerHello(try protocol.decode_public_key_hello(payload));
                got_hello = true;
            },
            control_candidate => if (!got_candidate) {
                _ = try bootstrap.acceptCandidateSignal(payload, 1);
                got_candidate = true;
            },
            control_handshake => {
                const response = try bootstrap.receiveHandshake(try protocol.decode_secure_datagram_handshake(payload), 1);
                if (response) |message| {
                    var frame: [protocol.secure_datagram_handshake_frame_max_bytes]u8 = undefined;
                    try sendControl(&socket, peer, control_handshake, try protocol.encode_secure_datagram_handshake(message, frame[0..]));
                }
            },
            else => return error.InvalidControlFrame,
        }
        if (got_hello and got_candidate and !started_handshake and role == .client) {
            var frame: [protocol.secure_datagram_handshake_frame_max_bytes]u8 = undefined;
            try sendControl(&socket, peer, control_handshake, try protocol.encode_secure_datagram_handshake(try bootstrap.beginHandshake(1), frame[0..]));
            started_handshake = true;
        }
        if (bootstrap.handshake) |handshake| if (handshake.state == .authenticated) return;
    }
    return error.BootstrapTimedOut;
}

fn exchangePayload(role: Role, route: *runtime.DirectConnectivityRoute) !void {
    var channel = try runtime.P2PChannel.init(route, .{ .delivery = .ordered, .maximum_payload_bytes = 32 });
    var output: [64]u8 = undefined;
    switch (role) {
        .client => {
            var received_check = false;
            var attempts: usize = 0;
            while (attempts < 2_000) : (attempts += 1) {
                if (attempts % 10 == 0) _ = try route.sendCheck(false, 2);
                if (try route.poll(output[0..], 2)) |event| switch (event) {
                    .check_received => received_check = true,
                    else => {},
                };
                if (received_check) break;
                std.Thread.sleep(std.time.ns_per_ms);
            }
            if (!received_check) return error.CheckTimedOut;
            _ = try route.sendCheck(true, 3);
            _ = try channel.send("client-direct", 4);
            try receivePayload(&channel, output[0..], "server-direct", 4);
        },
        .server => {
            var replied = false;
            var nominated = false;
            var attempts: usize = 0;
            while (attempts < 2_000) : (attempts += 1) {
                if (try route.poll(output[0..], 2)) |event| switch (event) {
                    .check_received => if (!replied) {
                        _ = try route.sendCheck(false, 2);
                        replied = true;
                    },
                    .nominated => nominated = true,
                    else => {},
                };
                if (nominated) break;
                std.Thread.sleep(std.time.ns_per_ms);
            }
            if (!nominated) return error.CheckTimedOut;
            _ = try channel.send("server-direct", 4);
            try receivePayload(&channel, output[0..], "client-direct", 4);
        },
    }
}

fn receivePayload(channel: *runtime.P2PChannel, output: []u8, expected: []const u8, now_ns: u64) !void {
    var attempts: usize = 0;
    while (attempts < 2_000) : (attempts += 1) {
        if (try channel.poll(output, now_ns)) |event| switch (event) {
            .received => |payload| {
                if (std.mem.eql(u8, payload, expected)) return;
                return error.UnexpectedPayload;
            },
            .failure => return error.RouteFailed,
            else => {},
        };
        std.Thread.sleep(std.time.ns_per_ms);
    }
    return error.PayloadTimedOut;
}

fn sendControl(socket: *transport.UdpSocket, peer: transport.Ipv4Address, kind: u8, payload: []const u8) !void {
    var frame: [512]u8 = undefined;
    if (payload.len > frame.len - 1) return error.ControlTooLarge;
    frame[0] = kind;
    @memcpy(frame[1..][0..payload.len], payload);
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        _ = socket.send_to(frame[0 .. payload.len + 1], peer) catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        return;
    }
    return error.ControlSendTimedOut;
}

fn candidate(address: transport.Ipv4Address) topology.NatCandidate {
    return .{ .kind = .host, .transport = .udp, .address = .{ .ipv4 = address }, .priority = 10, .expires_at_ns = 100 };
}

fn identitySeed(role: Role) [std.crypto.sign.Ed25519.KeyPair.seed_length]u8 {
    return if (role == .client) [_]u8{1} ** std.crypto.sign.Ed25519.KeyPair.seed_length else [_]u8{2} ** std.crypto.sign.Ed25519.KeyPair.seed_length;
}

fn opposite(role: Role) Role {
    return if (role == .client) .server else .client;
}

fn sameAddress(left: transport.Ipv4Address, right: transport.Ipv4Address) bool {
    return left.port == right.port and std.mem.eql(u8, &left.octets, &right.octets);
}
