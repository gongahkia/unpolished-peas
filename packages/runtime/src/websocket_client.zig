const std = @import("std");
const protocol = @import("minna-san-protocol");
const tls = @import("tls_client_route.zig");
const session = @import("websocket_session.zig");
const channel = @import("channel_registry.zig");
const upgrade = @import("websocket_upgrade.zig");

pub const max_websocket_uri_bytes: usize = 2048;
pub const max_websocket_client_subprotocols: usize = 16;
pub const WebSocketClientError = std.mem.Allocator.Error || tls.TlsClientRouteError || session.WebSocketSessionError || error{ InvalidConfiguration, InvalidUri, InvalidState, OutputTooSmall, HandshakeRejected, InvalidHandshake, SubprotocolRejected };
pub const WebSocketClientState = enum { idle, awaiting_handshake, open, cancelled, closed };
pub const WebSocketUri = struct { secure: bool, authority: []const u8, target: []const u8 };
pub const WebSocketClientConfig = struct {
    uri: []const u8,
    subprotocols: []const []const u8 = &.{},
    origin: ?[]const u8 = null,
    tls_route: ?*tls.TlsClientRoute = null,
    session: *session.WebSocketSession,
    nonce: ?[16]u8 = null,

    pub fn validate(self: WebSocketClientConfig) WebSocketClientError!void {
        _ = try parseWebSocketUri(self.uri);
        if (self.subprotocols.len > max_websocket_client_subprotocols) return error.InvalidConfiguration;
        for (self.subprotocols) |subprotocol| if (subprotocol.len == 0 or !isToken(subprotocol)) return error.InvalidConfiguration;
        if (self.origin) |origin| if (origin.len == 0 or containsCtl(origin)) return error.InvalidConfiguration;
    }
};

pub const WebSocketClient = struct {
    config: WebSocketClientConfig,
    uri: WebSocketUri,
    key: [24]u8 = undefined,
    expected_accept: [upgrade.websocket_accept_key_bytes]u8 = undefined,
    state: WebSocketClientState = .idle,

    pub fn init(config: WebSocketClientConfig) WebSocketClientError!WebSocketClient {
        try config.validate();
        return .{ .config = config, .uri = try parseWebSocketUri(config.uri) };
    }

    pub fn begin(self: *WebSocketClient, output: []u8) WebSocketClientError![]u8 {
        if (self.state != .idle) return error.InvalidState;
        var nonce: [16]u8 = self.config.nonce orelse undefined;
        if (self.config.nonce == null) std.crypto.random.bytes(&nonce);
        _ = std.base64.standard.Encoder.encode(self.key[0..], &nonce);
        self.expected_accept = upgrade.websocket_accept_key(&self.key);
        var stream = std.io.fixedBufferStream(output);
        const writer = stream.writer();
        writer.print("GET {s} HTTP/1.1\r\nHost: {s}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n", .{ self.uri.target, self.uri.authority, self.key }) catch return error.OutputTooSmall;
        if (self.config.origin) |origin| writer.print("Origin: {s}\r\n", .{origin}) catch return error.OutputTooSmall;
        if (self.config.subprotocols.len != 0) {
            writer.writeAll("Sec-WebSocket-Protocol: ") catch return error.OutputTooSmall;
            for (self.config.subprotocols, 0..) |subprotocol, index| {
                if (index != 0) writer.writeAll(", ") catch return error.OutputTooSmall;
                writer.writeAll(subprotocol) catch return error.OutputTooSmall;
            }
            writer.writeAll("\r\n") catch return error.OutputTooSmall;
        }
        writer.writeAll("\r\n") catch return error.OutputTooSmall;
        self.state = .awaiting_handshake;
        return stream.getWritten();
    }

    pub fn sendTlsHandshake(self: *WebSocketClient, output: []u8) WebSocketClientError!tls.TlsClientRouteWrite {
        const wire = try self.begin(output);
        const route = self.config.tls_route orelse return error.InvalidConfiguration;
        return route.send(wire);
    }

    pub fn acceptHandshake(self: *WebSocketClient, status: u16, headers: []const protocol.HttpHeader) WebSocketClientError!?[]const u8 {
        if (self.state != .awaiting_handshake) return error.InvalidState;
        if (status != 101) return error.HandshakeRejected;
        const connection = header(headers, "connection") orelse return error.InvalidHandshake;
        const upgrade_header = header(headers, "upgrade") orelse return error.InvalidHandshake;
        const accept = header(headers, "sec-websocket-accept") orelse return error.InvalidHandshake;
        if (!containsToken(connection, "upgrade") or !std.ascii.eqlIgnoreCase(std.mem.trim(u8, upgrade_header, " \t"), "websocket") or !std.mem.eql(u8, std.mem.trim(u8, accept, " \t"), &self.expected_accept)) return error.InvalidHandshake;
        const selected = header(headers, "sec-websocket-protocol");
        if (selected) |subprotocol| if (!containsExact(self.config.subprotocols, std.mem.trim(u8, subprotocol, " \t"))) return error.SubprotocolRejected;
        self.state = .open;
        return selected;
    }

    pub fn pollIncoming(self: *WebSocketClient) WebSocketClientError!?channel.QueuedMessage {
        if (self.state != .open) return error.InvalidState;
        return self.config.session.dequeueInbound();
    }

    pub fn pollOutgoing(self: *WebSocketClient) WebSocketClientError!?channel.QueuedMessage {
        if (self.state != .open) return error.InvalidState;
        return self.config.session.dequeueOutbound();
    }

    pub fn cancel(self: *WebSocketClient) void {
        if (self.state == .cancelled or self.state == .closed) return;
        if (self.config.tls_route) |route| route.close();
        self.state = .cancelled;
    }
};

pub fn parseWebSocketUri(uri: []const u8) WebSocketClientError!WebSocketUri {
    if (uri.len == 0 or uri.len > max_websocket_uri_bytes or containsCtl(uri)) return error.InvalidUri;
    const secure = if (std.mem.startsWith(u8, uri, "wss://")) true else if (std.mem.startsWith(u8, uri, "ws://")) false else return error.InvalidUri;
    const offset: usize = if (secure) 6 else 5;
    const remainder = uri[offset..];
    const slash = std.mem.indexOfScalar(u8, remainder, '/') orelse remainder.len;
    const authority = remainder[0..slash];
    if (authority.len == 0 or std.mem.indexOfAny(u8, authority, "@?#") != null) return error.InvalidUri;
    return .{ .secure = secure, .authority = authority, .target = if (slash == remainder.len) "/" else remainder[slash..] };
}

fn header(headers: []const protocol.HttpHeader, name: []const u8) ?[]const u8 {
    var result: ?[]const u8 = null;
    for (headers) |entry| {
        if (!std.ascii.eqlIgnoreCase(entry.name, name)) continue;
        if (result != null) return null;
        result = entry.value;
    }
    return result;
}

fn containsToken(value: []const u8, expected: []const u8) bool {
    var iterator = std.mem.splitScalar(u8, value, ',');
    while (iterator.next()) |item| if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, item, " \t"), expected)) return true;
    return false;
}

fn containsExact(values: []const []const u8, value: []const u8) bool {
    for (values) |item| if (std.mem.eql(u8, item, value)) return true;
    return false;
}
fn containsCtl(value: []const u8) bool {
    for (value) |byte| if (byte <= ' ' or byte == 0x7f) return true;
    return false;
}
fn isToken(value: []const u8) bool {
    for (value) |byte| if (!(std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", byte) != null)) return false;
    return true;
}

test "WebSocket clients complete a fixture handshake and select an offered subprotocol" {
    const websocket = @import("websocket_session.zig");
    const resource = @import("resource_handle.zig");
    const registry = @import("session_registry.zig");
    const payload_pool = @import("payload_pool.zig");
    const channels = @import("channel_registry.zig");
    const timers = @import("timer_wheel.zig");
    var resources = try resource.ResourceRegistry.init(std.testing.allocator, 3);
    defer resources.deinit();
    var sessions = try registry.SessionRegistry.init(std.testing.allocator, &resources, 1);
    defer sessions.deinit();
    const owner = try sessions.create();
    try sessions.transition(owner, .begin_establishing);
    try sessions.transition(owner, .mark_ready);
    var pool = try payload_pool.PayloadPool.init(std.testing.allocator, 2, 8);
    defer pool.deinit();
    var channel_registry = try channels.ChannelRegistry.init(std.testing.allocator, &resources, &sessions, &pool, 2);
    defer channel_registry.deinit();
    var wheel = try timers.TimerWheel.init(std.testing.allocator, 2);
    defer wheel.deinit();
    var websocket_session = try websocket.WebSocketSession.init(.{ .channels = &channel_registry, .timers = &wheel, .owner = owner, .maximum_message_bytes = 4, .maximum_in_flight_messages = 1, .ping_interval_ns = 10, .close_timeout_ns = 5 }, 0);
    defer websocket_session.deinit();
    var client = try WebSocketClient.init(.{ .uri = "wss://fixture.test/socket", .subprotocols = &.{"chat"}, .session = &websocket_session, .nonce = .{0} ** 16 });
    var request: [256]u8 = undefined;
    _ = try client.begin(request[0..]);
    const headers = [_]protocol.HttpHeader{ .{ .name = "Connection", .value = "Upgrade" }, .{ .name = "Upgrade", .value = "websocket" }, .{ .name = "Sec-WebSocket-Accept", .value = &client.expected_accept }, .{ .name = "Sec-WebSocket-Protocol", .value = "chat" } };
    try std.testing.expectEqualStrings("chat", (try client.acceptHandshake(101, &headers)).?);
    try websocket_session.receiveMessage("in");
    var inbound = (try client.pollIncoming()).?;
    defer inbound.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("in", inbound.payload);
    client.cancel();
    try std.testing.expectEqual(WebSocketClientState.cancelled, client.state);
}
