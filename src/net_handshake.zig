const std = @import("std");
const transport = @import("net_transport.zig");

pub const protocol_version: u16 = 1;
pub const client_hello_bytes: usize = 11;
pub const server_accept_bytes: usize = 19;
pub const server_reject_bytes: usize = 4;

const Kind = enum(u8) { client_hello = 1, server_accept = 2, server_reject = 3 };

pub const Rejection = enum(u8) { incompatible_version = 1, malformed_handshake = 2 };
pub const ClientHello = struct { protocol_version: u16, nonce: u64 };
pub const ServerAccept = struct { protocol_version: u16, nonce: u64, session_token: u64 };
pub const ServerReply = union(enum) {
    accept: ServerAccept,
    reject: struct { protocol_version: u16, reason: Rejection },
};
pub const Session = struct { peer: transport.Peer, protocol_version: u16, session_token: u64 };
pub const ClientState = enum { idle, connecting, connected, rejected };

pub fn encodeClientHello(destination: []u8, hello: ClientHello) ![]u8 {
    if (hello.protocol_version == 0 or hello.nonce == 0) return error.InvalidHandshake;
    if (destination.len < client_hello_bytes) return error.BufferTooSmall;
    std.mem.writeInt(u16, destination[0..2], hello.protocol_version, .little);
    destination[2] = @intFromEnum(Kind.client_hello);
    std.mem.writeInt(u64, destination[3..11], hello.nonce, .little);
    return destination[0..client_hello_bytes];
}

pub fn decodeClientHello(source: []const u8) !ClientHello {
    if (source.len != client_hello_bytes or source[2] != @intFromEnum(Kind.client_hello)) return error.MalformedHandshake;
    const hello = ClientHello{ .protocol_version = std.mem.readInt(u16, source[0..2], .little), .nonce = std.mem.readInt(u64, source[3..11], .little) };
    if (hello.protocol_version == 0 or hello.nonce == 0) return error.MalformedHandshake;
    return hello;
}

pub fn encodeServerReply(destination: []u8, reply: ServerReply) ![]u8 {
    switch (reply) {
        .accept => |accept| {
            if (accept.protocol_version == 0 or accept.nonce == 0 or accept.session_token == 0) return error.InvalidHandshake;
            if (destination.len < server_accept_bytes) return error.BufferTooSmall;
            std.mem.writeInt(u16, destination[0..2], accept.protocol_version, .little);
            destination[2] = @intFromEnum(Kind.server_accept);
            std.mem.writeInt(u64, destination[3..11], accept.nonce, .little);
            std.mem.writeInt(u64, destination[11..19], accept.session_token, .little);
            return destination[0..server_accept_bytes];
        },
        .reject => |reject| {
            if (reject.protocol_version == 0) return error.InvalidHandshake;
            if (destination.len < server_reject_bytes) return error.BufferTooSmall;
            std.mem.writeInt(u16, destination[0..2], reject.protocol_version, .little);
            destination[2] = @intFromEnum(Kind.server_reject);
            destination[3] = @intFromEnum(reject.reason);
            return destination[0..server_reject_bytes];
        },
    }
}

pub fn decodeServerReply(source: []const u8) !ServerReply {
    if (source.len < 3) return error.MalformedHandshake;
    const version = std.mem.readInt(u16, source[0..2], .little);
    if (version == 0) return error.MalformedHandshake;
    const kind = std.meta.intToEnum(Kind, source[2]) catch return error.MalformedHandshake;
    return switch (kind) {
        .client_hello => error.MalformedHandshake,
        .server_accept => accept: {
            if (source.len != server_accept_bytes) return error.MalformedHandshake;
            const nonce = std.mem.readInt(u64, source[3..11], .little);
            const token = std.mem.readInt(u64, source[11..19], .little);
            if (nonce == 0 or token == 0) return error.MalformedHandshake;
            break :accept .{ .accept = .{ .protocol_version = version, .nonce = nonce, .session_token = token } };
        },
        .server_reject => reject: {
            if (source.len != server_reject_bytes) return error.MalformedHandshake;
            const reason = std.meta.intToEnum(Rejection, source[3]) catch return error.MalformedHandshake;
            break :reject .{ .reject = .{ .protocol_version = version, .reason = reason } };
        },
    };
}

pub const ClientConfig = struct {
    protocol_version: u16 = protocol_version,
    retry_interval_ms: u64 = 250,
    max_attempts: u8 = 5,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    config: ClientConfig,
    state: ClientState = .idle,
    session: ?Session = null,
    rejection: ?Rejection = null,
    peer: ?transport.Peer = null,
    nonce: u64 = 0,
    attempts: u8 = 0,
    next_retry_at: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, config: ClientConfig) Client {
        return .{ .allocator = allocator, .config = config };
    }

    pub fn connect(self: *Client, peer: transport.Peer, nonce: u64) !void {
        if (self.config.protocol_version == 0 or self.config.retry_interval_ms == 0 or self.config.max_attempts == 0 or nonce == 0) return error.InvalidHandshakeConfig;
        self.state = .connecting;
        self.session = null;
        self.rejection = null;
        self.peer = peer;
        self.nonce = nonce;
        self.attempts = 0;
        self.next_retry_at = 0;
    }

    pub fn poll(self: *Client, net: transport.Transport) !void {
        try net.poll();
        while (net.receive()) |received| {
            var packet = received;
            defer packet.deinit(self.allocator);
            if (self.peer == null or packet.from.id != self.peer.?.id) continue;
            const reply = decodeServerReply(packet.bytes) catch |err| {
                self.state = .rejected;
                self.rejection = .malformed_handshake;
                return err;
            };
            try self.handleReply(reply);
        }
        if (self.state != .connecting) return;
        const now = net.now();
        if (now < self.next_retry_at) return;
        if (self.attempts >= self.config.max_attempts) {
            self.state = .rejected;
            return error.HandshakeTimedOut;
        }
        var bytes: [client_hello_bytes]u8 = undefined;
        try net.send(self.peer.?, try encodeClientHello(&bytes, .{ .protocol_version = self.config.protocol_version, .nonce = self.nonce }));
        self.attempts += 1;
        self.next_retry_at = now + self.config.retry_interval_ms;
    }

    fn handleReply(self: *Client, reply: ServerReply) !void {
        switch (reply) {
            .accept => |accept| {
                if (accept.protocol_version != self.config.protocol_version) {
                    self.state = .rejected;
                    self.rejection = .incompatible_version;
                    return error.IncompatibleVersion;
                }
                if (accept.nonce != self.nonce) return;
                self.session = .{ .peer = self.peer.?, .protocol_version = accept.protocol_version, .session_token = accept.session_token };
                self.state = .connected;
            },
            .reject => |reject| {
                self.state = .rejected;
                self.rejection = reject.reason;
                return switch (reject.reason) {
                    .incompatible_version => error.IncompatibleVersion,
                    .malformed_handshake => error.MalformedHandshake,
                };
            },
        }
    }
};

pub const ServerConfig = struct { protocol_version: u16 = protocol_version };

pub const Server = struct {
    allocator: std.mem.Allocator,
    config: ServerConfig,
    sessions: std.ArrayListUnmanaged(ServerSession) = .{},

    const ServerSession = struct { peer: transport.Peer, nonce: u64, session_token: u64 };

    pub fn init(allocator: std.mem.Allocator, config: ServerConfig) Server {
        return .{ .allocator = allocator, .config = config };
    }

    pub fn deinit(self: *Server) void {
        self.sessions.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn poll(self: *Server, net: transport.Transport) !void {
        try net.poll();
        while (net.receive()) |received| {
            var packet = received;
            defer packet.deinit(self.allocator);
            var bytes: [server_accept_bytes]u8 = undefined;
            try net.send(packet.from, try encodeServerReply(&bytes, try self.replyFor(packet.from, packet.bytes)));
        }
    }

    fn replyFor(self: *Server, peer: transport.Peer, bytes: []const u8) !ServerReply {
        const hello = decodeClientHello(bytes) catch return .{ .reject = .{ .protocol_version = self.config.protocol_version, .reason = .malformed_handshake } };
        if (hello.protocol_version != self.config.protocol_version) return .{ .reject = .{ .protocol_version = self.config.protocol_version, .reason = .incompatible_version } };
        for (self.sessions.items) |session| if (session.peer.id == peer.id and session.nonce == hello.nonce) return .{ .accept = .{ .protocol_version = self.config.protocol_version, .nonce = hello.nonce, .session_token = session.session_token } };
        const session_token = try self.newToken();
        try self.sessions.append(self.allocator, .{ .peer = peer, .nonce = hello.nonce, .session_token = session_token });
        return .{ .accept = .{ .protocol_version = self.config.protocol_version, .nonce = hello.nonce, .session_token = session_token } };
    }

    fn newToken(self: *Server) !u64 {
        var attempts: u8 = 0;
        while (attempts < 8) : (attempts += 1) {
            const token = std.crypto.random.int(u64);
            if (token == 0) continue;
            var duplicate = false;
            for (self.sessions.items) |session| if (session.session_token == token) {
                duplicate = true;
                break;
            };
            if (!duplicate) return token;
        }
        return error.SessionTokenCollision;
    }
};

test "handshake connects with an opaque session token" {
    var client_endpoint = transport.Loopback.init(std.testing.allocator, .{ .id = 1 });
    defer client_endpoint.deinit();
    var server_endpoint = transport.Loopback.init(std.testing.allocator, .{ .id = 2 });
    defer server_endpoint.deinit();
    transport.Loopback.pair(&client_endpoint, &server_endpoint);
    var client = Client.init(std.testing.allocator, .{});
    var server = Server.init(std.testing.allocator, .{});
    defer server.deinit();

    try client.connect(.{ .id = 2 }, 123);
    try client.poll(client_endpoint.transport());
    try server.poll(server_endpoint.transport());
    try client.poll(client_endpoint.transport());
    try std.testing.expectEqual(ClientState.connected, client.state);
    try std.testing.expect(client.session.?.session_token != 0);
    try std.testing.expectEqual(@as(usize, 1), server.sessions.items.len);
}

test "handshake completes over local UDP" {
    var server_endpoint = try transport.Udp.init(std.testing.allocator, .{ .bind_address = try std.net.Address.parseIp("127.0.0.1", 0), .receive_buffer_bytes = 16 * 1024, .send_buffer_bytes = 16 * 1024 });
    defer server_endpoint.deinit();
    var client_endpoint = try transport.Udp.init(std.testing.allocator, .{ .bind_address = try std.net.Address.parseIp("127.0.0.1", 0), .receive_buffer_bytes = 16 * 1024, .send_buffer_bytes = 16 * 1024 });
    defer client_endpoint.deinit();
    var client = Client.init(std.testing.allocator, .{ .retry_interval_ms = 5, .max_attempts = 20 });
    var server = Server.init(std.testing.allocator, .{});
    defer server.deinit();

    try client.connect(try client_endpoint.registerPeer(server_endpoint.local_address), 321);
    try client.poll(client_endpoint.transport());
    var attempts: usize = 0;
    while (client.state == .connecting and attempts < 100) : (attempts += 1) {
        try server.poll(server_endpoint.transport());
        try client.poll(client_endpoint.transport());
        std.Thread.sleep(std.time.ns_per_ms);
    }
    try std.testing.expectEqual(ClientState.connected, client.state);
    try std.testing.expect(client.session.?.session_token != 0);
}

test "handshake rejects incompatible versions and malformed client packets" {
    var client_endpoint = transport.Loopback.init(std.testing.allocator, .{ .id = 1 });
    defer client_endpoint.deinit();
    var server_endpoint = transport.Loopback.init(std.testing.allocator, .{ .id = 2 });
    defer server_endpoint.deinit();
    transport.Loopback.pair(&client_endpoint, &server_endpoint);
    var server = Server.init(std.testing.allocator, .{});
    defer server.deinit();

    var incompatible_client = Client.init(std.testing.allocator, .{ .protocol_version = 2 });
    try incompatible_client.connect(.{ .id = 2 }, 456);
    try incompatible_client.poll(client_endpoint.transport());
    try server.poll(server_endpoint.transport());
    try std.testing.expectError(error.IncompatibleVersion, incompatible_client.poll(client_endpoint.transport()));
    try std.testing.expectEqual(ClientState.rejected, incompatible_client.state);
    try std.testing.expectEqual(Rejection.incompatible_version, incompatible_client.rejection.?);

    try client_endpoint.transport().send(.{ .id = 2 }, "bad");
    try server.poll(server_endpoint.transport());
    var rejection = client_endpoint.transport().receive() orelse return error.TestExpectedEqual;
    defer rejection.deinit(std.testing.allocator);
    const decoded = try decodeServerReply(rejection.bytes);
    try std.testing.expectEqual(Rejection.malformed_handshake, decoded.reject.reason);
}

test "handshake retries preserve the first session token" {
    var client_endpoint = transport.Loopback.init(std.testing.allocator, .{ .id = 1 });
    defer client_endpoint.deinit();
    var server_endpoint = transport.Loopback.init(std.testing.allocator, .{ .id = 2 });
    defer server_endpoint.deinit();
    transport.Loopback.pair(&client_endpoint, &server_endpoint);
    var client = Client.init(std.testing.allocator, .{ .retry_interval_ms = 10 });
    var server = Server.init(std.testing.allocator, .{});
    defer server.deinit();

    try client.connect(.{ .id = 2 }, 789);
    try client.poll(client_endpoint.transport());
    try server.poll(server_endpoint.transport());
    var first = client_endpoint.transport().receive() orelse return error.TestExpectedEqual;
    defer first.deinit(std.testing.allocator);
    const first_reply = try decodeServerReply(first.bytes);

    client_endpoint.advance(10);
    try client.poll(client_endpoint.transport());
    try server.poll(server_endpoint.transport());
    var retried = client_endpoint.transport().receive() orelse return error.TestExpectedEqual;
    defer retried.deinit(std.testing.allocator);
    const retried_reply = try decodeServerReply(retried.bytes);
    try std.testing.expectEqual(first_reply.accept.session_token, retried_reply.accept.session_token);
    try std.testing.expectEqual(@as(usize, 1), server.sessions.items.len);
}
