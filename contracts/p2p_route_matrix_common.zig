const std = @import("std");
const protocol = @import("minna-san-protocol");
const runtime = @import("minna-san-runtime");
const topology = @import("minna-san-topology");
const transport = @import("minna-san-transport");

pub const Role = enum { server, client };

const relay_server_channel: u16 = 0x4001;
const relay_client_channel: u16 = 0x4002;

pub fn parsePort(value: []const u8) !u16 {
    const port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidArgument;
    if (port == 0) return error.InvalidArgument;
    return port;
}

pub fn runRelayPeer(role: Role, local_port: u16, relay_port: u16) !void {
    const local = try transport.Ipv4Address.parse("127.0.0.1", local_port);
    const relay = try transport.Ipv4Address.parse("127.0.0.1", relay_port);
    const server_peer = protocol.StunAddress{ .ipv4 = .{ .octets = .{ 10, 0, 0, 1 }, .port = 1 } };
    const client_peer = protocol.StunAddress{ .ipv4 = .{ .octets = .{ 10, 0, 0, 2 }, .port = 2 } };
    const server_to_client = protocol.PacketProtectionKey.init([_]u8{1} ** protocol.packet_protection_key_bytes, [_]u8{2} ** protocol.packet_protection_nonce_prefix_bytes);
    const client_to_server = protocol.PacketProtectionKey.init([_]u8{3} ** protocol.packet_protection_key_bytes, [_]u8{4} ** protocol.packet_protection_nonce_prefix_bytes);
    const allocation = topology.TurnAllocation{ .relay = .{ .ipv4 = .{ .octets = relay.octets, .port = relay.port } }, .expires_at_ns = 100 };
    var route = try runtime.TurnRelayDatagramRoute.init(std.heap.page_allocator, .{
        .allocation = allocation,
        .local_address = local,
        .permission_lifetime_ns = 50,
        .send_key = if (role == .server) server_to_client else client_to_server,
        .receive_key = if (role == .server) client_to_server else server_to_client,
    });
    defer route.deinit();
    const peer = if (role == .server) client_peer else server_peer;
    const channel = if (role == .server) relay_server_channel else relay_client_channel;
    _ = try route.authorizePeer(peer, channel, 1);
    if (role == .server) try std.fs.File.stdout().deprecatedWriter().writeAll("ready\n");
    const outgoing = if (role == .server) "server-relay" else "client-relay";
    const expected = if (role == .server) "client-relay" else "server-relay";
    switch (try route.send(peer, outgoing, 2)) {
        .sent => {},
        .received => return error.RelaySendFailed,
        .failure => return error.RelaySendFailed,
    }
    try receiveRelayPayload(&route, expected);
    try std.fs.File.stdout().deprecatedWriter().writeAll("verified\n");
}

pub fn runRelay(relay_port: u16) !void {
    var relay = try transport.UdpSocket.init(.{});
    defer relay.close();
    try relay.bind(try transport.Ipv4Address.parse("127.0.0.1", relay_port));
    try std.fs.File.stdout().deprecatedWriter().writeAll("ready\n");
    var frames: [2][transport.max_ipv4_datagram_bytes]u8 = undefined;
    var lengths: [2]usize = undefined;
    var sources: [2]transport.Ipv4Address = undefined;
    var count: usize = 0;
    var storage: [transport.max_ipv4_datagram_bytes]u8 = undefined;
    var attempts: usize = 0;
    while (attempts < 2_000 and count < frames.len) : (attempts += 1) {
        const received = relay.receive_from(storage[0..]) catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        if (received.bytes.len < 4 or received.bytes.len > frames[count].len) return error.InvalidRelayFrame;
        if (count == 1 and sameAddress(sources[0], received.source)) return error.DuplicateRelayPeer;
        @memcpy(frames[count][0..received.bytes.len], received.bytes);
        lengths[count] = received.bytes.len;
        sources[count] = received.source;
        count += 1;
    }
    if (count != frames.len) return error.RelayTimedOut;
    var forwarded: [transport.max_ipv4_datagram_bytes]u8 = undefined;
    _ = try relay.send_to(try rewriteChannel(frames[0][0..lengths[0]], try oppositeChannel(frames[0][0..lengths[0]]), forwarded[0..]), sources[1]);
    _ = try relay.send_to(try rewriteChannel(frames[1][0..lengths[1]], try oppositeChannel(frames[1][0..lengths[1]]), forwarded[0..]), sources[0]);
}

pub fn runTcpServer(port: u16) !void {
    var clock = runtime.ManualClock.init(0);
    const sdk = try runtime.SdkConfigBuilder.init().with_clock(clock.clock()).build();
    var server = try runtime.Runtime.init(std.heap.page_allocator, sdk);
    defer server.deinit();
    const endpoint = try runtime.Ipv4Address.parse("127.0.0.1", port);
    const listener = try server.openTcpListener(.{ .endpoint = endpoint, .backlog = 1 });
    defer server.closeTcpListener(listener) catch {};
    try std.fs.File.stdout().deprecatedWriter().writeAll("ready\n");
    var accepted: ?runtime.TcpListenerAccept = null;
    var attempts: usize = 0;
    while (attempts < 2_000) : (attempts += 1) {
        if ((try server.pollTcpListener(listener)).readable) accepted = try server.acceptTcpListener(listener);
        if (accepted != null) break;
        std.Thread.sleep(std.time.ns_per_ms);
    }
    var pending = accepted orelse return error.TcpAcceptTimedOut;
    const session = try server.adoptTcpConnection(&pending.connection, pending.peer);
    defer server.closeTcpSession(session) catch {};
    const channel = try server.attachTcpChannel(session, .{ .delivery = .stream, .maximum_payload_bytes = 64 });
    try server.enqueueChannel(channel, "server-tcp");
    try flushTcpPayload(&server, session);
    try receiveTcpPayload(&server, session, "client-tcp");
    try std.fs.File.stdout().deprecatedWriter().writeAll("verified\n");
}

pub fn runTcpClient(server_port: u16) !void {
    var clock = runtime.ManualClock.init(0);
    const sdk = try runtime.SdkConfigBuilder.init().with_clock(clock.clock()).build();
    var client = try runtime.Runtime.init(std.heap.page_allocator, sdk);
    defer client.deinit();
    const endpoint = try runtime.Ipv4Address.parse("127.0.0.1", server_port);
    const descriptor = runtime.ChannelDescriptor{ .delivery = .datagram, .maximum_payload_bytes = 64 };
    const udp_session = try client.dialUdp(.{ .endpoint = runtime.Endpoint.from_ipv4(endpoint), .family_policy = .ipv4_only, .platform_support = .{ .ipv4 = true, .ipv6 = false, .dual_stack = false }, .channel = descriptor });
    defer client.closeUdpSession(udp_session) catch {};
    try client.registerTcpFallback(udp_session, .{ .allowed_transport_bits = topology.route_transport_bit(.udp) | topology.route_transport_bit(.tcp) });
    const candidates = [_]topology.RouteCandidate{
        .{ .id = 1, .transport = .udp, .endpoint = runtime.Endpoint.from_ipv4(endpoint), .negotiated = true, .health = .healthy },
        .{ .id = 2, .transport = .tcp, .endpoint = runtime.Endpoint.from_ipv4(endpoint), .negotiated = true, .health = .healthy },
    };
    const fallback = try client.selectTcpFallback(udp_session, .send_failed, candidates[0..]);
    if (fallback.candidate.candidate.id != 2 or fallback.candidate.candidate.transport != .tcp) return error.TcpFallbackNotSelected;
    const session = try client.dialTcp(.{ .endpoint = runtime.Endpoint.from_ipv4(endpoint), .family_policy = .ipv4_only, .platform_support = .{ .ipv4 = true, .ipv6 = false, .dual_stack = false }, .timeout_ms = 2_000 });
    defer client.closeTcpSession(session) catch {};
    var connected = false;
    var attempts: u32 = 0;
    while (attempts < 2_000) : (attempts += 1) {
        if ((try client.pollTcpSession(session, attempts)).outcome == .ready) {
            connected = true;
            break;
        }
        std.Thread.sleep(std.time.ns_per_ms);
    }
    if (!connected) return error.TcpConnectTimedOut;
    const channel = try client.attachTcpChannel(session, .{ .delivery = .stream, .maximum_payload_bytes = 64 });
    try client.enqueueChannel(channel, "client-tcp");
    try flushTcpPayload(&client, session);
    try receiveTcpPayload(&client, session, "server-tcp");
    try std.fs.File.stdout().deprecatedWriter().writeAll("verified\n");
}

fn receiveRelayPayload(route: *runtime.TurnRelayDatagramRoute, expected: []const u8) !void {
    var output: [64]u8 = undefined;
    var attempts: usize = 0;
    while (attempts < 2_000) : (attempts += 1) {
        if (try route.poll(output[0..], 3)) |event| switch (event) {
            .received => |value| {
                if (!std.mem.eql(u8, value.payload, expected)) return error.UnexpectedRelayPayload;
                return;
            },
            .failure => return error.RelayReceiveFailed,
            else => {},
        };
        std.Thread.sleep(std.time.ns_per_ms);
    }
    return error.RelayPayloadTimedOut;
}

fn flushTcpPayload(value: *runtime.Runtime, session: anytype) !void {
    var attempts: usize = 0;
    while (attempts < 2_000) : (attempts += 1) {
        if ((try value.flushTcpChannel(session)).sent) return;
        std.Thread.sleep(std.time.ns_per_ms);
    }
    return error.TcpFlushTimedOut;
}

fn receiveTcpPayload(value: *runtime.Runtime, session: anytype, expected: []const u8) !void {
    var attempts: usize = 0;
    while (attempts < 2_000) : (attempts += 1) {
        if (try value.receiveTcpChannel(session)) |received| {
            var message = received;
            defer message.deinit(std.heap.page_allocator);
            if (!std.mem.eql(u8, message.message.payload, expected)) return error.UnexpectedTcpPayload;
            return;
        }
        std.Thread.sleep(std.time.ns_per_ms);
    }
    return error.TcpPayloadTimedOut;
}

fn oppositeChannel(frame: []const u8) !u16 {
    if (frame.len < 4) return error.InvalidRelayFrame;
    return switch (std.mem.readInt(u16, frame[0..2], .big)) {
        relay_server_channel => relay_client_channel,
        relay_client_channel => relay_server_channel,
        else => error.InvalidRelayChannel,
    };
}

fn rewriteChannel(frame: []const u8, channel: u16, output: []u8) ![]const u8 {
    if (frame.len < 4 or frame.len > output.len) return error.InvalidRelayFrame;
    const payload_len: usize = std.mem.readInt(u16, frame[2..4], .big);
    if (frame.len != 4 + payload_len) return error.InvalidRelayFrame;
    std.mem.writeInt(u16, output[0..2], channel, .big);
    std.mem.writeInt(u16, output[2..4], @intCast(payload_len), .big);
    @memcpy(output[4..][0..payload_len], frame[4..]);
    return output[0 .. 4 + payload_len];
}

fn sameAddress(left: transport.Ipv4Address, right: transport.Ipv4Address) bool {
    return left.port == right.port and std.mem.eql(u8, &left.octets, &right.octets);
}
