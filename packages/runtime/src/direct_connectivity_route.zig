const std = @import("std");
const core = @import("minna-san-core");
const protocol = @import("minna-san-protocol");
const topology = @import("minna-san-topology");
const transport = @import("minna-san-transport");

const check_frame_bytes: usize = 19;

const DirectFrameKind = enum(u8) { check = 1, application = 2 };

pub const DirectConnectivityRouteState = enum { checking, nominated, active, failed };
pub const DirectConnectivityRouteError = transport.UdpSocketError || transport.UdpDatagramError || topology.NatCandidateError || protocol.PacketProtectionError || protocol.ReplayWindowError || error{ InvalidConfiguration, CandidateExpired, InvalidState, OutputTooSmall };
pub const DirectConnectivityRouteConfig = struct {
    pair: topology.CandidatePair,
    local_address: transport.Ipv4Address = transport.Ipv4Address.wildcard(0),
    session_intent: u64,
    role: topology.ConnectivityRole,
    tie_breaker: u64,
    send_key: protocol.PacketProtectionKey,
    receive_key: protocol.PacketProtectionKey,
    replay: protocol.ReplayWindowConfig = .{},

    pub fn validate(self: DirectConnectivityRouteConfig, now_ns: core.TimeNs) DirectConnectivityRouteError!transport.Ipv4Address {
        if (self.session_intent == 0 or self.tie_breaker == 0 or self.pair.state != .nominated) return error.InvalidConfiguration;
        try topology.validate_nat_candidate(self.pair.local, now_ns);
        try topology.validate_nat_candidate(self.pair.remote, now_ns);
        _ = try protocol.ReplayWindow.init(self.replay);
        return switch (self.pair.remote.address) {
            .ipv4 => |address| .{ .octets = address.octets, .port = address.port },
            .ipv6 => error.InvalidConfiguration,
        };
    }
};
pub const DirectConnectivityRouteFailure = enum { candidate_expired, unexpected_source, authentication, replay, malformed_frame, session_mismatch, role_conflict, not_nominated, send_failed };
pub const DirectConnectivityRouteEvent = union(enum) {
    check_received: struct { remote_role: topology.ConnectivityRole, nominate: bool },
    nominated: void,
    sent: usize,
    received: []const u8,
    failure: DirectConnectivityRouteFailure,
};

pub const DirectConnectivityRoute = struct {
    socket: transport.UdpSocket,
    pair: topology.CandidatePair,
    peer: transport.Ipv4Address,
    session_intent: u64,
    role: topology.ConnectivityRole,
    tie_breaker: u64,
    state: DirectConnectivityRouteState = .checking,
    sender: protocol.PacketProtector,
    receiver: protocol.PacketProtector,
    replay: protocol.ReplayWindow,

    pub fn init(config: DirectConnectivityRouteConfig, now_ns: core.TimeNs) DirectConnectivityRouteError!DirectConnectivityRoute {
        const peer = try config.validate(now_ns);
        var socket = try transport.UdpSocket.init(.{});
        errdefer socket.close();
        try socket.bind(config.local_address);
        return .{
            .socket = socket,
            .pair = config.pair,
            .peer = peer,
            .session_intent = config.session_intent,
            .role = config.role,
            .tie_breaker = config.tie_breaker,
            .sender = protocol.PacketProtector.init(config.send_key),
            .receiver = protocol.PacketProtector.init(config.receive_key),
            .replay = try protocol.ReplayWindow.init(config.replay),
        };
    }

    pub fn deinit(self: *DirectConnectivityRoute) void {
        self.socket.close();
        self.sender.deinit();
        self.receiver.deinit();
        self.* = undefined;
    }

    pub fn localAddress(self: *DirectConnectivityRoute) !transport.Ipv4Address {
        var native = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
        var length = native.getOsSockLen();
        try std.posix.getsockname(self.socket.socket.handle, &native.any, &length);
        return transport.Ipv4Address.from_native(native);
    }

    pub fn sendCheck(self: *DirectConnectivityRoute, nominate: bool, now_ns: core.TimeNs) DirectConnectivityRouteError!DirectConnectivityRouteEvent {
        if (self.expired(now_ns)) return .{ .failure = .candidate_expired };
        if (self.state == .failed or (nominate and self.role != .controlling)) return error.InvalidState;
        var frame: [check_frame_bytes]u8 = undefined;
        frame[0] = @intFromEnum(DirectFrameKind.check);
        std.mem.writeInt(u64, frame[1..9], self.session_intent, .big);
        frame[9] = @intFromEnum(self.role);
        std.mem.writeInt(u64, frame[10..18], self.tie_breaker, .big);
        frame[18] = @intFromBool(nominate);
        const event = try self.sendFrame(&frame);
        if (nominate) self.state = .nominated;
        return event;
    }

    pub fn send(self: *DirectConnectivityRoute, payload: []const u8, now_ns: core.TimeNs) DirectConnectivityRouteError!DirectConnectivityRouteEvent {
        if (self.expired(now_ns)) return .{ .failure = .candidate_expired };
        if (self.state != .nominated and self.state != .active) return .{ .failure = .not_nominated };
        if (payload.len > protocol.max_packet_payload_bytes - 9) return .{ .failure = .send_failed };
        var frame: [protocol.max_packet_payload_bytes]u8 = undefined;
        frame[0] = @intFromEnum(DirectFrameKind.application);
        std.mem.writeInt(u64, frame[1..9], self.session_intent, .big);
        @memcpy(frame[9..][0..payload.len], payload);
        return self.sendFrame(frame[0 .. 9 + payload.len]);
    }

    pub fn poll(self: *DirectConnectivityRoute, output: []u8, now_ns: core.TimeNs) DirectConnectivityRouteError!?DirectConnectivityRouteEvent {
        if (self.expired(now_ns)) return .{ .failure = .candidate_expired };
        var storage: [transport.max_ipv4_datagram_bytes]u8 = undefined;
        const datagram = self.socket.receive_from(storage[0..]) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => return .{ .failure = .malformed_frame },
        };
        if (!sameAddress(datagram.source, self.peer)) return .{ .failure = .unexpected_source };
        var plaintext: [protocol.max_packet_payload_bytes]u8 = undefined;
        const opened = self.receiver.open_with_replay(&self.replay, datagram.bytes, plaintext[0..]) catch |err| switch (err) {
            error.DuplicatePacket, error.TooOldPacket => return .{ .failure = .replay },
            error.OutputTooSmall => return error.OutputTooSmall,
            else => return .{ .failure = .authentication },
        };
        if (opened.payload.len < 9) return .{ .failure = .malformed_frame };
        const kind = std.meta.intToEnum(DirectFrameKind, opened.payload[0]) catch return .{ .failure = .malformed_frame };
        if (std.mem.readInt(u64, opened.payload[1..9], .big) != self.session_intent) return .{ .failure = .session_mismatch };
        switch (kind) {
            .check => return self.receiveCheck(opened.payload),
            .application => return try self.receiveApplication(opened.payload, output),
        }
    }

    fn receiveCheck(self: *DirectConnectivityRoute, frame: []const u8) DirectConnectivityRouteEvent {
        if (frame.len != check_frame_bytes or frame[18] > 1) return .{ .failure = .malformed_frame };
        const remote_role = std.meta.intToEnum(topology.ConnectivityRole, frame[9]) catch return .{ .failure = .malformed_frame };
        const remote_tie_breaker = std.mem.readInt(u64, frame[10..18], .big);
        if (remote_tie_breaker == 0) return .{ .failure = .malformed_frame };
        if (remote_role == self.role) {
            if (remote_tie_breaker == self.tie_breaker) {
                self.state = .failed;
                return .{ .failure = .role_conflict };
            }
            if (remote_tie_breaker > self.tie_breaker) self.role = switch (self.role) {
                .controlling => .controlled,
                .controlled => .controlling,
            };
        }
        const nominate = frame[18] == 1;
        if (nominate) {
            if (remote_role != .controlling or self.role != .controlled) {
                self.state = .failed;
                return .{ .failure = .role_conflict };
            }
            self.state = .active;
            return .nominated;
        }
        return .{ .check_received = .{ .remote_role = remote_role, .nominate = false } };
    }

    fn receiveApplication(self: *DirectConnectivityRoute, frame: []const u8, output: []u8) DirectConnectivityRouteError!DirectConnectivityRouteEvent {
        if (self.state != .nominated and self.state != .active) return .{ .failure = .not_nominated };
        const payload = frame[9..];
        if (output.len < payload.len) return error.OutputTooSmall;
        @memcpy(output[0..payload.len], payload);
        return .{ .received = output[0..payload.len] };
    }

    fn sendFrame(self: *DirectConnectivityRoute, frame: []const u8) DirectConnectivityRouteError!DirectConnectivityRouteEvent {
        var protected: [transport.max_ipv4_datagram_bytes]u8 = undefined;
        const encrypted = self.sender.seal(frame, protected[0..]) catch return .{ .failure = .send_failed };
        _ = self.socket.send_to(encrypted, self.peer) catch return .{ .failure = .send_failed };
        return .{ .sent = frame.len };
    }

    fn expired(self: DirectConnectivityRoute, now_ns: core.TimeNs) bool {
        return topology.candidate_expired(self.pair.local, now_ns) or topology.candidate_expired(self.pair.remote, now_ns);
    }
};

fn sameAddress(first: transport.Ipv4Address, second: transport.Ipv4Address) bool {
    return first.port == second.port and std.mem.eql(u8, &first.octets, &second.octets);
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

fn pollWithRetry(route: *DirectConnectivityRoute, output: []u8, now_ns: core.TimeNs) !DirectConnectivityRouteEvent {
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (try route.poll(output, now_ns)) |event| return event;
        std.Thread.sleep(std.time.ns_per_ms);
    }
    return error.WouldBlock;
}

fn nominatedPair(local: transport.Ipv4Address, remote: transport.Ipv4Address) topology.CandidatePair {
    const make = struct {
        fn candidate(address: transport.Ipv4Address) topology.NatCandidate {
            return .{ .kind = .host, .transport = .udp, .address = .{ .ipv4 = address }, .priority = 1, .expires_at_ns = 100 };
        }
    }.candidate;
    return .{ .local = make(local), .remote = make(remote), .priority = 1, .state = .nominated };
}

test "NAT-simulated peers establish a nominated authenticated direct route from signaled candidates" {
    const first_address = try reserveLoopbackAddress();
    const second_address = try reserveLoopbackAddress();
    const first_to_second = protocol.PacketProtectionKey.init([_]u8{1} ** protocol.packet_protection_key_bytes, [_]u8{2} ** protocol.packet_protection_nonce_prefix_bytes);
    const second_to_first = protocol.PacketProtectionKey.init([_]u8{3} ** protocol.packet_protection_key_bytes, [_]u8{4} ** protocol.packet_protection_nonce_prefix_bytes);
    var first = try DirectConnectivityRoute.init(.{ .pair = nominatedPair(first_address, second_address), .local_address = first_address, .session_intent = 9, .role = .controlling, .tie_breaker = 2, .send_key = first_to_second, .receive_key = second_to_first }, 0);
    defer first.deinit();
    var second = try DirectConnectivityRoute.init(.{ .pair = nominatedPair(second_address, first_address), .local_address = second_address, .session_intent = 9, .role = .controlled, .tie_breaker = 1, .send_key = second_to_first, .receive_key = first_to_second }, 0);
    defer second.deinit();
    try std.testing.expectEqual(DirectConnectivityRouteEvent{ .sent = check_frame_bytes }, try first.sendCheck(false, 1));
    var output: [32]u8 = undefined;
    try std.testing.expectEqual(DirectConnectivityRouteEvent{ .check_received = .{ .remote_role = .controlling, .nominate = false } }, try pollWithRetry(&second, output[0..], 1));
    try std.testing.expectEqual(DirectConnectivityRouteEvent{ .sent = check_frame_bytes }, try second.sendCheck(false, 1));
    try std.testing.expectEqual(DirectConnectivityRouteEvent{ .check_received = .{ .remote_role = .controlled, .nominate = false } }, try pollWithRetry(&first, output[0..], 1));
    _ = try first.sendCheck(true, 2);
    try std.testing.expectEqual(DirectConnectivityRouteEvent.nominated, try pollWithRetry(&second, output[0..], 2));
    try std.testing.expectEqual(DirectConnectivityRouteState.nominated, first.state);
    try std.testing.expectEqual(DirectConnectivityRouteState.active, second.state);
    try std.testing.expectEqual(DirectConnectivityRouteEvent{ .sent = 12 }, try first.send("direct route", 3));
    try std.testing.expectEqualStrings("direct route", (try pollWithRetry(&second, output[0..], 3)).received);
}

test "direct connectivity attributes forged sources and expired candidates" {
    const local = try reserveLoopbackAddress();
    const remote = try reserveLoopbackAddress();
    const key = protocol.PacketProtectionKey.init([_]u8{5} ** protocol.packet_protection_key_bytes, [_]u8{6} ** protocol.packet_protection_nonce_prefix_bytes);
    var route = try DirectConnectivityRoute.init(.{ .pair = nominatedPair(local, remote), .local_address = local, .session_intent = 1, .role = .controlled, .tie_breaker = 1, .send_key = key, .receive_key = key }, 0);
    defer route.deinit();
    var attacker = try transport.UdpSocket.init(.{});
    defer attacker.close();
    try attacker.bind(transport.Ipv4Address.wildcard(0));
    _ = try attacker.send_to("forged", local);
    var output: [32]u8 = undefined;
    try std.testing.expectEqual(DirectConnectivityRouteEvent{ .failure = .unexpected_source }, try pollWithRetry(&route, output[0..], 1));
    route.pair.local.expires_at_ns = 2;
    try std.testing.expectEqual(DirectConnectivityRouteEvent{ .failure = .candidate_expired }, try route.sendCheck(false, 2));
}
