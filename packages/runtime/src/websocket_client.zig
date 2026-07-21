const std = @import("std");
const core = @import("minna-san-core");
const protocol = @import("minna-san-protocol");
const tls = @import("tls_client_route.zig");
const session = @import("websocket_session.zig");
const channel = @import("channel_registry.zig");
const upgrade = @import("websocket_upgrade.zig");

pub const max_websocket_uri_bytes: usize = 2048;
pub const max_websocket_client_subprotocols: usize = 16;
pub const max_websocket_client_headers: usize = 16;
const max_websocket_client_header_bytes: usize = 8 * 1024;
pub const WebSocketClientError = std.mem.Allocator.Error || protocol.HttpParserError || protocol.WebSocketFrameError || tls.TlsClientRouteError || session.WebSocketSessionError || error{ InvalidConfiguration, InvalidUri, InvalidState, OutputTooSmall, HandshakeRejected, InvalidHandshake, SubprotocolRejected };
pub const WebSocketClientState = enum { idle, awaiting_handshake, open, cancelled, closed };
pub const WebSocketUri = struct { secure: bool, authority: []const u8, target: []const u8 };
pub const WebSocketClientEvent = union(enum) { handshake: ?[]const u8, frame: protocol.WebSocketFrameEvent };
pub const WebSocketClientFeed = struct { consumed: usize, event: ?WebSocketClientEvent };
pub const WebSocketClientConfig = struct {
    uri: []const u8,
    subprotocols: []const []const u8 = &.{},
    origin: ?[]const u8 = null,
    tls_route: ?*tls.TlsClientRoute = null,
    session: *session.WebSocketSession,
    nonce: ?[16]u8 = null,
    allocator: std.mem.Allocator = std.heap.page_allocator,

    pub fn validate(self: WebSocketClientConfig) WebSocketClientError!void {
        _ = try parseWebSocketUri(self.uri);
        if (self.session.maximum_message_bytes > protocol.max_websocket_frame_bytes) return error.InvalidConfiguration;
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
    handshake_parser: protocol.HttpParser,
    handshake_status: ?u16 = null,
    handshake_headers: [max_websocket_client_headers]protocol.HttpHeader = undefined,
    handshake_header_count: usize = 0,
    handshake_header_storage: [max_websocket_client_header_bytes]u8 = undefined,
    handshake_header_storage_len: usize = 0,
    frame_parser: protocol.WebSocketFrameParser,
    message_buffer: []u8,
    message_length: usize = 0,
    state: WebSocketClientState = .idle,

    pub fn init(config: WebSocketClientConfig) WebSocketClientError!WebSocketClient {
        try config.validate();
        const maximum_frame_bytes = config.session.maximum_message_bytes;
        var frame_parser = try protocol.WebSocketFrameParser.init(config.allocator, .{ .endpoint = .client, .maximum_frame_bytes = maximum_frame_bytes, .maximum_chunk_bytes = @min(maximum_frame_bytes, protocol.max_websocket_chunk_bytes) });
        errdefer frame_parser.deinit();
        return .{
            .config = config,
            .uri = try parseWebSocketUri(config.uri),
            .handshake_parser = try protocol.HttpParser.init(.{ .kind = .response, .maximum_header_bytes = max_websocket_client_header_bytes, .maximum_headers = max_websocket_client_headers, .maximum_body_bytes = 0 }),
            .frame_parser = frame_parser,
            .message_buffer = try config.allocator.alloc(u8, maximum_frame_bytes),
        };
    }

    pub fn deinit(self: *WebSocketClient) void {
        self.cancel();
        self.frame_parser.deinit();
        self.config.allocator.free(self.message_buffer);
        self.* = undefined;
    }

    pub fn begin(self: *WebSocketClient, output: []u8) WebSocketClientError![]u8 {
        if (self.state != .idle) return error.InvalidState;
        self.handshake_parser.reset();
        self.handshake_status = null;
        self.handshake_header_count = 0;
        self.handshake_header_storage_len = 0;
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

    pub fn feed(self: *WebSocketClient, input: []const u8) WebSocketClientError!WebSocketClientFeed {
        return switch (self.state) {
            .awaiting_handshake => self.feedHandshake(input),
            .open => self.feedFrame(input),
            else => error.InvalidState,
        };
    }

    pub fn feedTls(self: *WebSocketClient, ciphertext: []u8, plaintext: []u8) WebSocketClientError!?WebSocketClientFeed {
        const route = self.config.tls_route orelse return error.InvalidConfiguration;
        const input = try route.receive(ciphertext, plaintext) orelse return null;
        return try self.feed(input);
    }

    pub fn sendTlsFrame(self: *WebSocketClient, opcode: protocol.WebSocketOpcode, payload: []const u8, output: []u8) WebSocketClientError!tls.TlsClientRouteWrite {
        if (self.state != .open) return error.InvalidState;
        const route = self.config.tls_route orelse return error.InvalidConfiguration;
        var mask_key: [4]u8 = undefined;
        std.crypto.random.bytes(&mask_key);
        const wire = try protocol.encode_websocket_frame(.{ .endpoint = .client, .maximum_frame_bytes = self.config.session.maximum_message_bytes }, .{ .opcode = opcode, .payload = payload, .mask_key = mask_key }, output);
        return route.send(wire);
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

    fn feedHandshake(self: *WebSocketClient, input: []const u8) WebSocketClientError!WebSocketClientFeed {
        const parsed = self.handshake_parser.feed(input) catch |err| {
            self.cancel();
            return err;
        };
        const event = parsed.event orelse return .{ .consumed = parsed.consumed, .event = null };
        switch (event) {
            .status_line => |line| self.handshake_status = line.status,
            .header => |entry| {
                if (self.handshake_header_count == self.handshake_headers.len or entry.name.len + entry.value.len > self.handshake_header_storage.len - self.handshake_header_storage_len) {
                    self.cancel();
                    return error.InvalidHandshake;
                }
                const name_start = self.handshake_header_storage_len;
                const name_end = name_start + entry.name.len;
                const value_end = name_end + entry.value.len;
                @memcpy(self.handshake_header_storage[name_start..name_end], entry.name);
                @memcpy(self.handshake_header_storage[name_end..value_end], entry.value);
                self.handshake_headers[self.handshake_header_count] = .{ .name = self.handshake_header_storage[name_start..name_end], .value = self.handshake_header_storage[name_end..value_end] };
                self.handshake_header_storage_len = value_end;
                self.handshake_header_count += 1;
            },
            .headers_complete => {
                const selected = self.acceptHandshake(self.handshake_status orelse return error.InvalidHandshake, self.handshake_headers[0..self.handshake_header_count]) catch |err| {
                    self.cancel();
                    return err;
                };
                return .{ .consumed = parsed.consumed, .event = .{ .handshake = selected } };
            },
            else => return error.InvalidHandshake,
        }
        return .{ .consumed = parsed.consumed, .event = .{ .handshake = null } };
    }

    fn feedFrame(self: *WebSocketClient, input: []const u8) WebSocketClientError!WebSocketClientFeed {
        const parsed = self.frame_parser.feed(input) catch |err| {
            self.cancel();
            return err;
        };
        const event = parsed.event orelse return .{ .consumed = parsed.consumed, .event = null };
        switch (event) {
            .payload => |payload| {
                const frame = self.frame_parser.current orelse unreachable;
                if (frame.opcode == .text or frame.opcode == .binary or frame.opcode == .continuation) {
                    if (payload.len > self.message_buffer.len - self.message_length) return error.InvalidHandshake;
                    @memcpy(self.message_buffer[self.message_length .. self.message_length + payload.len], payload);
                    self.message_length += payload.len;
                }
            },
            .frame_end => |frame| {
                if ((frame.opcode == .text or frame.opcode == .binary or frame.opcode == .continuation) and frame.fin) {
                    try self.config.session.receiveMessage(self.message_buffer[0..self.message_length]);
                    self.message_length = 0;
                }
                if (frame.opcode == .close) {
                    const code: u16 = if (self.frame_parser.control_length >= 2) std.mem.readInt(u16, self.frame_parser.control[0..2], .big) else 1000;
                    _ = try self.config.session.receiveClose(code);
                }
            },
            else => {},
        }
        return .{ .consumed = parsed.consumed, .event = .{ .frame = event } };
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

fn receiveFixture(socket: std.posix.socket_t, output: []u8) ![]u8 {
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        const received = std.posix.recv(socket, output, 0) catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        if (received != 0) return output[0..received];
    }
    return error.TestExpectedEqual;
}

fn receiveTlsFixture(route: *tls.TlsClientRoute, ciphertext: []u8, plaintext: []u8) ![]u8 {
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (try route.receive(ciphertext, plaintext)) |bytes| return bytes;
        std.Thread.sleep(std.time.ns_per_ms);
    }
    return error.TestExpectedEqual;
}

fn expectMaskedFixtureFrame(input: []const u8, opcode: protocol.WebSocketOpcode, payload: []const u8) !void {
    var parser = try protocol.WebSocketFrameParser.init(std.testing.allocator, .{ .endpoint = .server, .maximum_frame_bytes = 8, .maximum_chunk_bytes = 8 });
    defer parser.deinit();
    var offset: usize = 0;
    var saw_opcode = false;
    var saw_payload = false;
    while (offset < input.len) {
        const result = try parser.feed(input[offset..]);
        if (result.event) |event| switch (event) {
            .frame_start => |header_value| saw_opcode = header_value.opcode == opcode,
            .payload => |bytes| saw_payload = std.mem.eql(u8, bytes, payload),
            else => {},
        };
        offset += result.consumed;
        if (result.consumed == 0 and result.event == null) break;
    }
    try std.testing.expect(saw_opcode and saw_payload);
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
    var client = try WebSocketClient.init(.{ .uri = "wss://fixture.test/socket", .subprotocols = &.{"chat"}, .session = &websocket_session, .nonce = .{0} ** 16, .allocator = std.testing.allocator });
    defer client.deinit();
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

test "WebSocket clients exchange text and binary frames with an external TLS fixture" {
    const transport = @import("minna-san-transport");
    const resource = @import("resource_handle.zig");
    const registry = @import("session_registry.zig");
    const payload_pool = @import("payload_pool.zig");
    const timers = @import("timer_wheel.zig");
    const tcp_sessions = @import("tcp_session_registry.zig");
    const certificate_callbacks = @import("tls_certificate_callback.zig");
    const tls_provider = @import("tls_provider.zig");
    const TrustFixture = struct {
        fn begin(_: ?*anyopaque, _: certificate_callbacks.TlsCertificateRequest) void {}
        fn poll(_: ?*anyopaque, _: certificate_callbacks.TlsCertificateRequestId) ?certificate_callbacks.TlsCertificateResolution {
            return .{ .accepted = .client_trust };
        }
    };
    const FakeProvider = struct {
        polls: usize = 0,
        torn_down: bool = false,

        fn certificate(_: ?*anyopaque, _: [*]const u8, _: usize) callconv(.c) c_int {
            return @intFromEnum(tls_provider.TlsCertificateDecision.accept);
        }

        fn start(_: ?*anyopaque, _: u8, _: [*]const u8, _: usize, _: [*]const u8, _: usize, certificate_context: ?*anyopaque, callback: ?tls_provider.TlsCertificateCallback) callconv(.c) c_int {
            const name = "fixture.test";
            if (callback.?(certificate_context, name.ptr, name.len) != @intFromEnum(tls_provider.TlsCertificateDecision.accept)) return @intFromEnum(core.CResult.invalid_argument);
            return @intFromEnum(core.CResult.ok);
        }

        fn poll(context: ?*anyopaque, _: core.TimeNs, output: *tls_provider.TlsPollOutput) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.polls += 1;
            output.* = .{ .state = @intFromEnum(if (self.polls == 1) tls_provider.TlsState.handshaking else tls_provider.TlsState.connected), .work_completed = 1 };
            return @intFromEnum(core.CResult.ok);
        }

        fn encrypt(_: ?*anyopaque, input: [*]const u8, input_len: usize, output: [*]u8, output_len: usize, result: *tls_provider.TlsIoOutput) callconv(.c) c_int {
            if (output_len < input_len + 1) return @intFromEnum(core.CResult.resource_exhausted);
            output[0] = 0xa5;
            @memcpy(output[1..][0..input_len], input[0..input_len]);
            result.* = .{ .bytes = input_len + 1 };
            return @intFromEnum(core.CResult.ok);
        }

        fn decrypt(_: ?*anyopaque, input: [*]const u8, input_len: usize, output: [*]u8, output_len: usize, result: *tls_provider.TlsIoOutput) callconv(.c) c_int {
            if (input_len == 0 or input[0] != 0xa5 or output_len < input_len - 1) return @intFromEnum(core.CResult.invalid_argument);
            @memcpy(output[0 .. input_len - 1], input[1..input_len]);
            result.* = .{ .bytes = input_len - 1 };
            return @intFromEnum(core.CResult.ok);
        }

        fn teardown(context: ?*anyopaque) callconv(.c) void {
            @as(*@This(), @ptrCast(@alignCast(context.?))).torn_down = true;
        }
    };
    var listener = try transport.TcpListener.init(transport.Ipv4Address.wildcard(0), 1);
    defer listener.shutdown();
    const endpoint = try transport.Ipv4Address.parse("127.0.0.1", (try listener.local_address()).port);
    var resources = try resource.ResourceRegistry.init(std.testing.allocator, 5);
    defer resources.deinit();
    var sessions = try registry.SessionRegistry.init(std.testing.allocator, &resources, 2);
    defer sessions.deinit();
    const owner = try sessions.create();
    try sessions.transition(owner, .begin_establishing);
    try sessions.transition(owner, .mark_ready);
    var payloads = try payload_pool.PayloadPool.init(std.testing.allocator, 4, 8);
    defer payloads.deinit();
    var channel_registry = try channel.ChannelRegistry.init(std.testing.allocator, &resources, &sessions, &payloads, 4);
    defer channel_registry.deinit();
    var wheel = try timers.TimerWheel.init(std.testing.allocator, 2);
    defer wheel.deinit();
    var websocket_session = try session.WebSocketSession.init(.{ .channels = &channel_registry, .timers = &wheel, .owner = owner, .maximum_message_bytes = 8, .maximum_in_flight_messages = 2, .ping_interval_ns = 10, .close_timeout_ns = 5 }, 0);
    defer websocket_session.deinit();
    var tcp = try tcp_sessions.TcpSessionRegistry.init(std.testing.allocator, &sessions, 1);
    defer tcp.deinit();
    var callbacks = try certificate_callbacks.TlsCertificateCallbackRegistry.init(std.testing.allocator, .{ .callback = .{ .context = null, .begin = TrustFixture.begin, .poll = TrustFixture.poll }, .maximum_pending = 1, .maximum_server_identities = 1, .failure_event_capacity = 1 });
    defer callbacks.deinit();
    const tcp_session = try tcp.dial(.{ .endpoint = transport.Endpoint.from_ipv4(endpoint), .family_policy = .ipv4_only, .platform_support = .{ .ipv4 = true, .ipv6 = false, .dual_stack = false }, .timeout_ms = 1_000 });
    var fake = FakeProvider{};
    var route = try tls.TlsClientRoute.init(std.testing.allocator, .{ .tcp_sessions = &tcp, .session = tcp_session, .provider = try tls_provider.TlsProvider.init(.{ .role = .client, .alpn = "http/1.1", .server_name = "fixture.test", .certificate_context = &fake, .certificate_callback = FakeProvider.certificate }, &fake, .{ .start = FakeProvider.start, .poll = FakeProvider.poll, .encrypt = FakeProvider.encrypt, .decrypt = FakeProvider.decrypt, .teardown = FakeProvider.teardown }), .certificate_callbacks = &callbacks, .peer_certificate_chain_id = 1, .handshake_timeout_ns = 100, .maximum_plaintext_bytes = 256, .maximum_ciphertext_bytes = 512 });
    defer route.deinit();
    var server: ?transport.TcpConnection = null;
    var tick: u64 = 0;
    while (route.state != .ready and tick < 100) : (tick += 1) {
        if (server == null) {
            var pending = listener.accept() catch |err| switch (err) {
                error.WouldBlock => null,
                else => return err,
            };
            if (pending) |*value| {
                if (listener.admit(value, .allow)) |accepted| server = accepted.connection;
            }
        }
        _ = try route.poll(tick, @intCast(tick));
        std.Thread.sleep(std.time.ns_per_ms);
    }
    var server_connection = server orelse return error.TestExpectedEqual;
    defer server_connection.close();
    try std.testing.expectEqual(tls.TlsClientRouteState.ready, route.state);
    var client = try WebSocketClient.init(.{ .uri = "wss://fixture.test/socket", .subprotocols = &.{"chat"}, .tls_route = &route, .session = &websocket_session, .nonce = .{0} ** 16, .allocator = std.testing.allocator });
    defer client.deinit();
    const server_socket = (server_connection.socket orelse return error.TestExpectedEqual).handle;
    var request: [256]u8 = undefined;
    _ = try client.sendTlsHandshake(request[0..]);
    var wire: [512]u8 = undefined;
    const request_wire = try receiveFixture(server_socket, wire[0..]);
    try std.testing.expect(std.mem.startsWith(u8, request_wire, "\xa5GET /socket HTTP/1.1\r\n"));
    var response: [256]u8 = undefined;
    const response_plain = try std.fmt.bufPrint(response[1..], "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: {s}\r\nSec-WebSocket-Protocol: chat\r\n\r\n", .{&client.expected_accept});
    response[0] = 0xa5;
    _ = try std.posix.send(server_socket, response[0 .. response_plain.len + 1], 0);
    var ciphertext: [512]u8 = undefined;
    var plaintext: [512]u8 = undefined;
    const handshake = try receiveTlsFixture(&route, ciphertext[0..], plaintext[0..256]);
    var offset: usize = 0;
    var selected: ?[]const u8 = null;
    while (offset < handshake.len) {
        const result = try client.feed(handshake[offset..]);
        offset += result.consumed;
        if (result.event) |event| switch (event) {
            .handshake => |value| {
                if (value) |subprotocol| selected = subprotocol;
            },
            else => {},
        };
    }
    try std.testing.expectEqualStrings("chat", selected.?);
    var frames: [64]u8 = undefined;
    const text = try protocol.encode_websocket_frame(.{ .endpoint = .server, .maximum_frame_bytes = 8 }, .{ .opcode = .text, .payload = "hello" }, frames[1..]);
    const binary = try protocol.encode_websocket_frame(.{ .endpoint = .server, .maximum_frame_bytes = 8 }, .{ .opcode = .binary, .payload = "\x01\x02" }, frames[1 + text.len ..]);
    frames[0] = 0xa5;
    _ = try std.posix.send(server_socket, frames[0 .. text.len + binary.len + 1], 0);
    const incoming = try receiveTlsFixture(&route, ciphertext[0..], plaintext[0..256]);
    offset = 0;
    while (offset < incoming.len) {
        const result = try client.feed(incoming[offset..]);
        offset += result.consumed;
        if (result.consumed == 0 and result.event == null) break;
    }
    _ = try client.feed(&.{});
    var text_message = (try client.pollIncoming()).?;
    defer text_message.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hello", text_message.payload);
    var binary_message = (try client.pollIncoming()).?;
    defer binary_message.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("\x01\x02", binary_message.payload);
    var outgoing: [32]u8 = undefined;
    _ = try client.sendTlsFrame(.text, "ack", outgoing[0..]);
    const text_wire = try receiveFixture(server_socket, wire[0..]);
    try std.testing.expectEqual(@as(u8, 0xa5), text_wire[0]);
    try expectMaskedFixtureFrame(text_wire[1..], .text, "ack");
    _ = try client.sendTlsFrame(.binary, "\x03", outgoing[0..]);
    const binary_wire = try receiveFixture(server_socket, wire[0..]);
    try std.testing.expectEqual(@as(u8, 0xa5), binary_wire[0]);
    try expectMaskedFixtureFrame(binary_wire[1..], .binary, "\x03");
    client.cancel();
    try std.testing.expect(client.state == .cancelled and fake.torn_down);
}
