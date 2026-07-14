const std = @import("std");
const handshake = @import("net_handshake.zig");
const net_codec = @import("net_codec.zig");
const transport = @import("net_transport.zig");

pub const session_token_bytes: usize = 8;

pub const Config = struct {
    protocol_version: u16 = handshake.protocol_version,
    max_peers: usize = 16,
    heartbeat_interval_ms: u64 = 1_000,
    timeout_ms: u64 = 5_000,
};

pub const DisconnectReason = enum { requested, timeout, reconnected };
pub const Event = union(enum) { // input events own decoded messages; call deinit with the Server allocator.
    connected: handshake.Session,
    disconnected: struct { session: handshake.Session, reason: DisconnectReason },
    rejected: struct { peer: transport.Peer, reason: handshake.Rejection },
    input: struct { session: handshake.Session, message: net_codec.OwnedMessage },

    pub fn deinit(self: *Event, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .input => |*input| input.message.deinit(allocator),
            else => {},
        }
        self.* = undefined;
    }
};

pub fn encodeSessionMessage(destination: []u8, kind: net_codec.Kind, sequence: u32, session_token: u64, payload: []const u8) ![]u8 {
    if (session_token == 0 or payload.len > net_codec.max_payload_bytes - session_token_bytes) return error.InvalidSessionMessage;
    var authenticated: [net_codec.max_payload_bytes]u8 = undefined;
    std.mem.writeInt(u64, authenticated[0..session_token_bytes], session_token, .little);
    @memcpy(authenticated[session_token_bytes..][0..payload.len], payload);
    return net_codec.encode(destination, .{ .kind = kind, .sequence = sequence, .payload = authenticated[0 .. session_token_bytes + payload.len] });
}

pub const Server = struct { // owns peer and event queues allocated by init; call deinit once.
    allocator: std.mem.Allocator,
    config: Config,
    handshake_server: handshake.Server,
    peers: std.ArrayListUnmanaged(TrackedPeer) = .{},
    events: std.ArrayListUnmanaged(Event) = .{},

    const TrackedPeer = struct { session: handshake.Session, last_seen_at: u64 };

    pub fn init(allocator: std.mem.Allocator, config: Config) !Server {
        if (config.protocol_version == 0 or config.max_peers == 0 or config.heartbeat_interval_ms == 0 or config.timeout_ms < config.heartbeat_interval_ms) return error.InvalidPeerServerConfig;
        return .{
            .allocator = allocator,
            .config = config,
            .handshake_server = handshake.Server.init(allocator, .{ .protocol_version = config.protocol_version, .max_sessions = config.max_peers }),
        };
    }

    pub fn deinit(self: *Server) void {
        for (self.events.items) |*event| event.deinit(self.allocator);
        self.events.deinit(self.allocator);
        self.peers.deinit(self.allocator);
        self.handshake_server.deinit();
        self.* = undefined;
    }

    pub fn poll(self: *Server, net: transport.Transport) !void {
        try net.poll();
        const now = net.now();
        try self.expire(now);
        while (net.receive()) |received| {
            var packet = received;
            defer packet.deinit(self.allocator);
            if (looksLikeClientHello(packet.bytes)) {
                var reply_bytes: [handshake.server_accept_bytes]u8 = undefined;
                const reply = try self.handshake_server.handleHello(packet.from, packet.bytes);
                try net.send(packet.from, try handshake.encodeServerReply(&reply_bytes, reply));
                if (reply == .reject) try self.events.append(self.allocator, .{ .rejected = .{ .peer = packet.from, .reason = reply.reject.reason } });
                try self.drainAccepted(now);
                continue;
            }
            var message = net_codec.decode(self.allocator, packet.bytes) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => continue,
            };
            var owns_message = true;
            defer if (owns_message) message.deinit(self.allocator);
            if (try self.handleMessage(packet.from, now, &message)) owns_message = false;
        }
    }

    pub fn nextEvent(self: *Server) ?Event {
        if (self.events.items.len == 0) return null;
        return self.events.orderedRemove(0);
    }

    fn drainAccepted(self: *Server, now: u64) !void {
        while (self.handshake_server.takeAccepted()) |session| {
            if (self.findPeer(session.peer)) |index| try self.disconnect(index, .reconnected);
            try self.peers.append(self.allocator, .{ .session = session, .last_seen_at = now });
            try self.events.append(self.allocator, .{ .connected = session });
        }
    }

    fn handleMessage(self: *Server, peer: transport.Peer, now: u64, message: *net_codec.OwnedMessage) !bool {
        if (message.payload.len < session_token_bytes) return false;
        const session_token = std.mem.readInt(u64, message.payload[0..session_token_bytes], .little);
        const index = self.findPeer(peer) orelse return false;
        if (self.peers.items[index].session.session_token != session_token) return false;
        self.peers.items[index].last_seen_at = now;
        const session = self.peers.items[index].session;
        switch (message.kind) {
            .input => {
                try self.events.append(self.allocator, .{ .input = .{ .session = session, .message = message.* } });
                return true;
            },
            .disconnect => {
                if (message.payload.len != session_token_bytes) return false;
                try self.disconnect(index, .requested);
            },
            .ping => if (message.payload.len != session_token_bytes) return false,
            else => {},
        }
        return false;
    }

    fn expire(self: *Server, now: u64) !void {
        var index: usize = 0;
        while (index < self.peers.items.len) {
            const peer = self.peers.items[index];
            if (now < peer.last_seen_at or now - peer.last_seen_at < self.config.timeout_ms) {
                index += 1;
                continue;
            }
            try self.disconnect(index, .timeout);
        }
    }

    fn disconnect(self: *Server, index: usize, reason: DisconnectReason) !void {
        const peer = self.peers.orderedRemove(index).session;
        self.handshake_server.removePeer(peer.peer);
        try self.events.append(self.allocator, .{ .disconnected = .{ .session = peer, .reason = reason } });
    }

    fn findPeer(self: Server, peer: transport.Peer) ?usize {
        for (self.peers.items, 0..) |entry, index| if (entry.session.peer.id == peer.id) return index;
        return null;
    }

    fn looksLikeClientHello(bytes: []const u8) bool {
        return bytes.len == handshake.client_hello_bytes and bytes[2] == 1;
    }
};

test "peer server handles capacity, authenticated input, timeout, and reconnect" {
    var server_endpoint = try transport.Udp.init(std.testing.allocator, .{ .bind_address = try std.net.Address.parseIp("127.0.0.1", 0), .receive_buffer_bytes = 16 * 1024, .send_buffer_bytes = 16 * 1024 });
    defer server_endpoint.deinit();
    var first_endpoint = try transport.Udp.init(std.testing.allocator, .{ .bind_address = try std.net.Address.parseIp("127.0.0.1", 0), .receive_buffer_bytes = 16 * 1024, .send_buffer_bytes = 16 * 1024 });
    defer first_endpoint.deinit();
    var second_endpoint = try transport.Udp.init(std.testing.allocator, .{ .bind_address = try std.net.Address.parseIp("127.0.0.1", 0), .receive_buffer_bytes = 16 * 1024, .send_buffer_bytes = 16 * 1024 });
    defer second_endpoint.deinit();
    var third_endpoint = try transport.Udp.init(std.testing.allocator, .{ .bind_address = try std.net.Address.parseIp("127.0.0.1", 0), .receive_buffer_bytes = 16 * 1024, .send_buffer_bytes = 16 * 1024 });
    defer third_endpoint.deinit();
    var server = try Server.init(std.testing.allocator, .{ .max_peers = 2, .heartbeat_interval_ms = 5, .timeout_ms = 50 });
    defer server.deinit();
    var first = handshake.Client.init(std.testing.allocator, .{ .retry_interval_ms = 5, .max_attempts = 50 });
    var second = handshake.Client.init(std.testing.allocator, .{ .retry_interval_ms = 5, .max_attempts = 50 });
    var third = handshake.Client.init(std.testing.allocator, .{ .retry_interval_ms = 5, .max_attempts = 50 });
    const first_server = try first_endpoint.registerPeer(server_endpoint.local_address);
    const second_server = try second_endpoint.registerPeer(server_endpoint.local_address);
    const third_server = try third_endpoint.registerPeer(server_endpoint.local_address);
    const first_on_server = try server_endpoint.registerPeer(first_endpoint.local_address);
    const second_on_server = try server_endpoint.registerPeer(second_endpoint.local_address);

    try first.connect(first_server, 1);
    try first.poll(first_endpoint.transport());
    var attempts: usize = 0;
    while (first.state == .connecting and attempts < 100) : (attempts += 1) {
        try server.poll(server_endpoint.transport());
        try first.poll(first_endpoint.transport());
        std.Thread.sleep(std.time.ns_per_ms);
    }
    try std.testing.expectEqual(handshake.ClientState.connected, first.state);

    try second.connect(second_server, 2);
    try second.poll(second_endpoint.transport());
    attempts = 0;
    while (second.state == .connecting and attempts < 100) : (attempts += 1) {
        try server.poll(server_endpoint.transport());
        try second.poll(second_endpoint.transport());
        std.Thread.sleep(std.time.ns_per_ms);
    }
    try std.testing.expectEqual(handshake.ClientState.connected, second.state);

    try third.connect(third_server, 3);
    try third.poll(third_endpoint.transport());
    var capacity_rejected = false;
    attempts = 0;
    while (third.state == .connecting and attempts < 100) : (attempts += 1) {
        try server.poll(server_endpoint.transport());
        third.poll(third_endpoint.transport()) catch |err| switch (err) {
            error.CapacityReached => capacity_rejected = true,
            else => return err,
        };
        std.Thread.sleep(std.time.ns_per_ms);
    }
    try std.testing.expectEqual(handshake.ClientState.rejected, third.state);
    try std.testing.expect(capacity_rejected);

    var joined: usize = 0;
    var rejected: usize = 0;
    while (server.nextEvent()) |received| {
        var event = received;
        defer event.deinit(std.testing.allocator);
        switch (event) {
            .connected => joined += 1,
            .rejected => |value| {
                if (value.reason == .capacity_reached) rejected += 1;
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 2), joined);
    try std.testing.expect(rejected >= 1);

    var input_bytes: [net_codec.header_bytes + session_token_bytes + 4]u8 = undefined;
    try first_endpoint.transport().send(first_server, try encodeSessionMessage(&input_bytes, .input, 7, first.session.?.session_token, "move"));
    var input_received = false;
    attempts = 0;
    while (!input_received and attempts < 100) : (attempts += 1) {
        try server.poll(server_endpoint.transport());
        while (server.nextEvent()) |received| {
            var event = received;
            defer event.deinit(std.testing.allocator);
            switch (event) {
                .input => |value| {
                    try std.testing.expectEqual(first.session.?.session_token, value.session.session_token);
                    try std.testing.expectEqualStrings("move", value.message.payload[session_token_bytes..]);
                    input_received = true;
                },
                else => {},
            }
        }
        std.Thread.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(input_received);

    std.Thread.sleep(30 * std.time.ns_per_ms);
    var heartbeat_bytes: [net_codec.header_bytes + session_token_bytes]u8 = undefined;
    try second_endpoint.transport().send(second_server, try encodeSessionMessage(&heartbeat_bytes, .ping, 8, second.session.?.session_token, ""));
    const second_index = server.findPeer(second_on_server) orelse return error.TestExpectedEqual;
    const previous_second_seen_at = server.peers.items[second_index].last_seen_at;
    var heartbeat_processed = false;
    attempts = 0;
    while (attempts < 100) : (attempts += 1) {
        try server.poll(server_endpoint.transport());
        const index = server.findPeer(second_on_server) orelse return error.TestExpectedEqual;
        if (server.peers.items[index].last_seen_at > previous_second_seen_at) {
            heartbeat_processed = true;
            break;
        }
        std.Thread.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(heartbeat_processed);
    std.Thread.sleep(30 * std.time.ns_per_ms);
    try server.poll(server_endpoint.transport());
    var timed_out = false;
    while (server.nextEvent()) |received| {
        var event = received;
        defer event.deinit(std.testing.allocator);
        switch (event) {
            .disconnected => |value| {
                if (value.session.peer.id == first_on_server.id and value.reason == .timeout) timed_out = true;
            },
            else => {},
        }
    }
    try std.testing.expect(timed_out);
    try std.testing.expectEqual(@as(usize, 1), server.peers.items.len);

    try first.connect(first_server, 4);
    try first.poll(first_endpoint.transport());
    attempts = 0;
    while (first.state == .connecting and attempts < 100) : (attempts += 1) {
        try server.poll(server_endpoint.transport());
        try first.poll(first_endpoint.transport());
        std.Thread.sleep(std.time.ns_per_ms);
    }
    try std.testing.expectEqual(handshake.ClientState.connected, first.state);
    var rejoined = false;
    while (server.nextEvent()) |received| {
        var event = received;
        defer event.deinit(std.testing.allocator);
        switch (event) {
            .connected => |session| {
                if (session.peer.id == first_on_server.id) rejoined = true;
            },
            else => {},
        }
    }
    try std.testing.expect(rejoined);

    var disconnect_bytes: [net_codec.header_bytes + session_token_bytes]u8 = undefined;
    try first_endpoint.transport().send(first_server, try encodeSessionMessage(&disconnect_bytes, .disconnect, 9, first.session.?.session_token, ""));
    var disconnected = false;
    attempts = 0;
    while (!disconnected and attempts < 100) : (attempts += 1) {
        try server.poll(server_endpoint.transport());
        while (server.nextEvent()) |received| {
            var event = received;
            defer event.deinit(std.testing.allocator);
            switch (event) {
                .disconnected => |value| {
                    if (value.session.peer.id == first_on_server.id and value.reason == .requested) disconnected = true;
                },
                else => {},
            }
        }
        std.Thread.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(disconnected);
}
