const std = @import("std");
const core = @import("minna-san-core");
const protocol = @import("minna-san-protocol");
const topology = @import("minna-san-topology");
const transport = @import("minna-san-transport");

pub const max_turn_relay_route_peers: usize = core.max_session_capacity;
pub const TurnRelayDatagramRouteError = transport.UdpSocketError || transport.UdpDatagramError || topology.TurnPermissionChannelLifecycleError || protocol.PacketProtectionError || protocol.ReplayWindowError || error{ InvalidConfiguration, AllocationExpired, UnknownPeer };
pub const TurnRelayDatagramRouteConfig = struct {
    allocation: topology.TurnAllocation,
    local_address: transport.Ipv4Address = transport.Ipv4Address.wildcard(0),
    maximum_peers: usize = 64,
    permission_lifetime_ns: core.TimeNs,
    send_key: protocol.PacketProtectionKey,
    receive_key: protocol.PacketProtectionKey,
    replay: protocol.ReplayWindowConfig = .{},

    pub fn validate(self: TurnRelayDatagramRouteConfig) TurnRelayDatagramRouteError!transport.Ipv4Address {
        if (self.maximum_peers == 0 or self.maximum_peers > max_turn_relay_route_peers or self.permission_lifetime_ns == 0) return error.InvalidConfiguration;
        _ = try protocol.ReplayWindow.init(self.replay);
        return switch (self.allocation.relay) {
            .ipv4 => |address| transport.Ipv4Address{ .octets = address.octets, .port = address.port },
            .ipv6 => error.InvalidConfiguration,
        };
    }
};
pub const TurnRelayRouteFailure = enum { allocation_expired, unknown_peer, unauthorized_peer, unexpected_source, malformed_channel, authentication, replay, send_failed };
pub const TurnRelayRouteEvent = union(enum) {
    sent: struct { peer: protocol.StunAddress, payload_len: usize },
    received: struct { peer: protocol.StunAddress, payload: []const u8 },
    failure: TurnRelayRouteFailure,
};

pub const TurnRelayDatagramRoute = struct {
    socket: transport.UdpSocket,
    relay: transport.Ipv4Address,
    expires_at_ns: core.TimeNs,
    lifecycle: topology.TurnPermissionChannelLifecycle,
    sender: protocol.PacketProtector,
    receiver: protocol.PacketProtector,
    replay: protocol.ReplayWindow,

    pub fn init(allocator: std.mem.Allocator, config: TurnRelayDatagramRouteConfig) TurnRelayDatagramRouteError!TurnRelayDatagramRoute {
        const relay = try config.validate();
        var socket = try transport.UdpSocket.init(.{});
        errdefer socket.close();
        try socket.bind(config.local_address);
        var lifecycle = try topology.TurnPermissionChannelLifecycle.init(allocator, .{ .maximum_permissions = config.maximum_peers, .permission_lifetime_ns = config.permission_lifetime_ns, .maximum_channels = config.maximum_peers });
        errdefer lifecycle.deinit();
        return .{ .socket = socket, .relay = relay, .expires_at_ns = config.allocation.expires_at_ns, .lifecycle = lifecycle, .sender = protocol.PacketProtector.init(config.send_key), .receiver = protocol.PacketProtector.init(config.receive_key), .replay = try protocol.ReplayWindow.init(config.replay) };
    }

    pub fn deinit(self: *TurnRelayDatagramRoute) void {
        self.socket.close();
        self.lifecycle.deinit();
        self.sender.deinit();
        self.receiver.deinit();
        self.* = undefined;
    }

    pub fn localAddress(self: *TurnRelayDatagramRoute) !transport.Ipv4Address {
        var native = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
        var length = native.getOsSockLen();
        try std.posix.getsockname(self.socket.socket.handle, &native.any, &length);
        return transport.Ipv4Address.from_native(native);
    }

    pub fn authorizePeer(self: *TurnRelayDatagramRoute, peer: protocol.StunAddress, requested_channel: ?u16, now_ns: core.TimeNs) TurnRelayDatagramRouteError!topology.TurnChannelBinding {
        if (now_ns >= self.expires_at_ns) return error.AllocationExpired;
        _ = try self.lifecycle.authorize_peer(peer, now_ns);
        return self.lifecycle.assign_channel(peer, requested_channel, now_ns);
    }

    pub fn send(self: *TurnRelayDatagramRoute, peer: protocol.StunAddress, payload: []const u8, now_ns: core.TimeNs) TurnRelayDatagramRouteError!TurnRelayRouteEvent {
        if (now_ns >= self.expires_at_ns) return .{ .failure = .allocation_expired };
        const binding = self.lifecycle.channels.binding_for_peer(peer) orelse return .{ .failure = .unknown_peer };
        if (!self.lifecycle.permissions.authorized(peer, now_ns)) return .{ .failure = .unauthorized_peer };
        var protected: [transport.max_ipv4_datagram_bytes]u8 = undefined;
        const encrypted = self.sender.seal(payload, protected[0..]) catch return .{ .failure = .send_failed };
        var channel_data: [transport.max_ipv4_datagram_bytes]u8 = undefined;
        const frame = self.lifecycle.channels.encode(.{ .number = binding.number, .payload = encrypted }, channel_data[0..]) catch return .{ .failure = .send_failed };
        _ = self.socket.send_to(frame, self.relay) catch |err| switch (err) {
            error.WouldBlock => return .{ .failure = .send_failed },
            else => return .{ .failure = .send_failed },
        };
        return .{ .sent = .{ .peer = peer, .payload_len = payload.len } };
    }

    pub fn poll(self: *TurnRelayDatagramRoute, output: []u8, now_ns: core.TimeNs) TurnRelayDatagramRouteError!?TurnRelayRouteEvent {
        if (now_ns >= self.expires_at_ns) return .{ .failure = .allocation_expired };
        var storage: [transport.max_ipv4_datagram_bytes]u8 = undefined;
        const datagram = self.socket.receive_from(storage[0..]) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => return .{ .failure = .malformed_channel },
        };
        if (!sameAddress(datagram.source, self.relay)) return .{ .failure = .unexpected_source };
        const relayed = self.lifecycle.receive_channel(datagram.bytes, now_ns) catch |err| switch (err) {
            error.UnauthorizedPeer => return .{ .failure = .unauthorized_peer },
            error.UnknownChannel, error.MalformedChannelData => return .{ .failure = .malformed_channel },
            else => return .{ .failure = .malformed_channel },
        };
        const opened = self.receiver.open_with_replay(&self.replay, relayed.payload, output) catch |err| switch (err) {
            error.DuplicatePacket, error.TooOldPacket => return .{ .failure = .replay },
            else => return .{ .failure = .authentication },
        };
        return .{ .received = .{ .peer = relayed.peer, .payload = opened.payload } };
    }

    pub fn teardown(self: *TurnRelayDatagramRoute) void {
        self.lifecycle.teardown();
    }
};

fn sameAddress(first: transport.Ipv4Address, second: transport.Ipv4Address) bool {
    return first.port == second.port and std.mem.eql(u8, &first.octets, &second.octets);
}

fn receiveWithRetry(socket: *transport.UdpSocket, storage: []u8) !transport.ReceivedDatagram {
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        return socket.receive_from(storage) catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
    }
    return error.WouldBlock;
}

fn rewriteChannel(frame: []const u8, number: u16, output: []u8) ![]u8 {
    if (frame.len < 4 or frame.len > output.len) return error.InvalidFrame;
    const payload_len: usize = std.mem.readInt(u16, frame[2..4], .big);
    if (frame.len != 4 + payload_len) return error.InvalidFrame;
    std.mem.writeInt(u16, output[0..2], number, .big);
    std.mem.writeInt(u16, output[2..4], @intCast(payload_len), .big);
    @memcpy(output[4..][0..payload_len], frame[4..]);
    return output[0 .. 4 + payload_len];
}

test "TURN relay datagram routes exchange protected payloads solely through a relay" {
    var relay = try transport.UdpSocket.init(.{});
    defer relay.close();
    try relay.bind(transport.Ipv4Address.wildcard(0));
    var native = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
    var length = native.getOsSockLen();
    try std.posix.getsockname(relay.socket.handle, &native.any, &length);
    const relay_address = try transport.Ipv4Address.parse("127.0.0.1", (try transport.Ipv4Address.from_native(native)).port);
    const allocation = topology.TurnAllocation{ .relay = .{ .ipv4 = .{ .octets = relay_address.octets, .port = relay_address.port } }, .expires_at_ns = 100 };
    const a_to_b = protocol.PacketProtectionKey.init([_]u8{1} ** protocol.packet_protection_key_bytes, [_]u8{2} ** protocol.packet_protection_nonce_prefix_bytes);
    const b_to_a = protocol.PacketProtectionKey.init([_]u8{3} ** protocol.packet_protection_key_bytes, [_]u8{4} ** protocol.packet_protection_nonce_prefix_bytes);
    var first = try TurnRelayDatagramRoute.init(std.testing.allocator, .{ .allocation = allocation, .permission_lifetime_ns = 50, .send_key = a_to_b, .receive_key = b_to_a });
    defer first.deinit();
    var second = try TurnRelayDatagramRoute.init(std.testing.allocator, .{ .allocation = allocation, .permission_lifetime_ns = 50, .send_key = b_to_a, .receive_key = a_to_b });
    defer second.deinit();
    const first_peer = protocol.StunAddress{ .ipv4 = .{ .octets = .{ 10, 0, 0, 1 }, .port = 1 } };
    const second_peer = protocol.StunAddress{ .ipv4 = .{ .octets = .{ 10, 0, 0, 2 }, .port = 2 } };
    const first_channel = try first.authorizePeer(second_peer, 0x4001, 0);
    const second_channel = try second.authorizePeer(first_peer, 0x4002, 0);
    try std.testing.expectEqual(TurnRelayRouteEvent{ .sent = .{ .peer = second_peer, .payload_len = 3 } }, try first.send(second_peer, "one", 1));
    var relay_storage: [transport.max_ipv4_datagram_bytes]u8 = undefined;
    const from_first = try receiveWithRetry(&relay, relay_storage[0..]);
    var first_frame: [transport.max_ipv4_datagram_bytes]u8 = undefined;
    @memcpy(first_frame[0..from_first.bytes.len], from_first.bytes);
    try std.testing.expectEqual(TurnRelayRouteEvent{ .sent = .{ .peer = first_peer, .payload_len = 3 } }, try second.send(first_peer, "two", 1));
    const from_second = try receiveWithRetry(&relay, relay_storage[0..]);
    var forwarded: [transport.max_ipv4_datagram_bytes]u8 = undefined;
    const first_local = try transport.Ipv4Address.parse("127.0.0.1", (try first.localAddress()).port);
    const second_local = try transport.Ipv4Address.parse("127.0.0.1", (try second.localAddress()).port);
    _ = try relay.send_to(try rewriteChannel(from_second.bytes, first_channel.number, forwarded[0..]), first_local);
    _ = try relay.send_to(try rewriteChannel(first_frame[0..from_first.bytes.len], second_channel.number, forwarded[0..]), second_local);
    var first_output: [32]u8 = undefined;
    var second_output: [32]u8 = undefined;
    var received_first = false;
    var received_second = false;
    var attempts: usize = 0;
    while (attempts < 100 and (!received_first or !received_second)) : (attempts += 1) {
        if (try first.poll(first_output[0..], 2)) |event| switch (event) {
            .received => |value| {
                try std.testing.expectEqual(second_peer, value.peer);
                try std.testing.expectEqualStrings("two", value.payload);
                received_first = true;
            },
            else => return error.TestUnexpectedResult,
        };
        if (try second.poll(second_output[0..], 2)) |event| switch (event) {
            .received => |value| {
                try std.testing.expectEqual(first_peer, value.peer);
                try std.testing.expectEqualStrings("one", value.payload);
                received_second = true;
            },
            else => return error.TestUnexpectedResult,
        };
        std.Thread.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(received_first and received_second);
}

test "TURN relay datagram routes map unexpected relay sources into failure events" {
    var relay = try transport.UdpSocket.init(.{});
    defer relay.close();
    try relay.bind(transport.Ipv4Address.wildcard(0));
    var native = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
    var length = native.getOsSockLen();
    try std.posix.getsockname(relay.socket.handle, &native.any, &length);
    const relay_address = try transport.Ipv4Address.parse("127.0.0.1", (try transport.Ipv4Address.from_native(native)).port);
    const key = protocol.PacketProtectionKey.init([_]u8{7} ** protocol.packet_protection_key_bytes, [_]u8{8} ** protocol.packet_protection_nonce_prefix_bytes);
    var route = try TurnRelayDatagramRoute.init(std.testing.allocator, .{ .allocation = .{ .relay = .{ .ipv4 = .{ .octets = relay_address.octets, .port = relay_address.port } }, .expires_at_ns = 10 }, .permission_lifetime_ns = 5, .send_key = key, .receive_key = key });
    defer route.deinit();
    var attacker = try transport.UdpSocket.init(.{});
    defer attacker.close();
    try attacker.bind(transport.Ipv4Address.wildcard(0));
    _ = try attacker.send_to("forged", try transport.Ipv4Address.parse("127.0.0.1", (try route.localAddress()).port));
    var output: [32]u8 = undefined;
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (try route.poll(output[0..], 1)) |event| {
            try std.testing.expectEqual(TurnRelayRouteEvent{ .failure = .unexpected_source }, event);
            break;
        }
        std.Thread.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(attempts < 100);
}
