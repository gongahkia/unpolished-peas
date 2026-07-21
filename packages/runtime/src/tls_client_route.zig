const std = @import("std");
const core = @import("minna-san-core");
const channel_delivery = @import("channel_delivery.zig");
const resource = @import("resource_handle.zig");
const tcp_sessions = @import("tcp_session_registry.zig");
const tls_certificate_callback = @import("tls_certificate_callback.zig");
const tls_provider = @import("tls_provider.zig");

pub const max_tls_client_record_bytes: usize = 16 * 1024;
pub const TlsClientRouteState = enum { connecting, verifying_certificate, handshaking, ready, failed, closed };
pub const TlsClientRouteFailure = enum { tcp_refused, tcp_failed, tcp_timed_out, tcp_cancelled, certificate_rejected, certificate_expired, tls_handshake, tls_timeout, peer_closed, read_failed, write_failed };
pub const TlsClientRouteError = std.mem.Allocator.Error || tcp_sessions.TcpSessionRegistryError || tls_certificate_callback.TlsCertificateCallbackError || tls_provider.TlsProviderError || channel_delivery.ChannelDeliveryError || error{ InvalidConfiguration, InvalidState, PayloadTooLarge, WritePending, ConnectionClosed, ReadFailed, WriteFailed };

pub const TlsClientRouteConfig = struct {
    tcp_sessions: *tcp_sessions.TcpSessionRegistry,
    session: *resource.ResourceHandle,
    provider: tls_provider.TlsProvider,
    certificate_callbacks: *tls_certificate_callback.TlsCertificateCallbackRegistry,
    peer_certificate_chain_id: tls_certificate_callback.TlsCertificateChainId,
    handshake_timeout_ns: core.TimeNs,
    maximum_plaintext_bytes: usize,
    maximum_ciphertext_bytes: usize,

    pub fn validate(self: TlsClientRouteConfig) TlsClientRouteError!void {
        if (self.peer_certificate_chain_id == 0 or self.handshake_timeout_ns == 0 or self.maximum_plaintext_bytes == 0 or self.maximum_plaintext_bytes > max_tls_client_record_bytes or self.maximum_ciphertext_bytes < self.maximum_plaintext_bytes or self.maximum_ciphertext_bytes > max_tls_client_record_bytes) return error.InvalidConfiguration;
    }
};

pub const TlsClientRoutePoll = struct {
    state: TlsClientRouteState,
    tcp_outcome: ?tcp_sessions.TcpSessionOutcome = null,
    tls_work_completed: usize = 0,
    failure: ?TlsClientRouteFailure = null,
};

pub const TlsClientRouteWrite = struct {
    sent_ciphertext_bytes: usize,
    pending_ciphertext_bytes: usize,
};

pub const TlsClientRoute = struct {
    allocator: std.mem.Allocator,
    tcp_sessions: *tcp_sessions.TcpSessionRegistry,
    session: *resource.ResourceHandle,
    provider: tls_provider.TlsProvider,
    certificate_callbacks: *tls_certificate_callback.TlsCertificateCallbackRegistry,
    peer_certificate_chain_id: tls_certificate_callback.TlsCertificateChainId,
    handshake_timeout_ns: core.TimeNs,
    maximum_plaintext_bytes: usize,
    write_buffer: []u8,
    certificate_request_id: ?tls_certificate_callback.TlsCertificateRequestId = null,
    handshake_deadline_ns: ?core.TimeNs = null,
    state: TlsClientRouteState = .connecting,
    write_offset: usize = 0,
    write_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, config: TlsClientRouteConfig) TlsClientRouteError!TlsClientRoute {
        try config.validate();
        _ = try config.tcp_sessions.connection(config.session);
        const write_buffer = try allocator.alloc(u8, config.maximum_ciphertext_bytes);
        return .{
            .allocator = allocator,
            .tcp_sessions = config.tcp_sessions,
            .session = config.session,
            .provider = config.provider,
            .certificate_callbacks = config.certificate_callbacks,
            .peer_certificate_chain_id = config.peer_certificate_chain_id,
            .handshake_timeout_ns = config.handshake_timeout_ns,
            .maximum_plaintext_bytes = config.maximum_plaintext_bytes,
            .write_buffer = write_buffer,
        };
    }

    pub fn deinit(self: *TlsClientRoute) void {
        self.close();
        self.allocator.free(self.write_buffer);
        self.* = undefined;
    }

    pub fn poll(self: *TlsClientRoute, now_ns: core.TimeNs, elapsed_ms: u32) TlsClientRouteError!TlsClientRoutePoll {
        return switch (self.state) {
            .connecting => self.pollTcp(now_ns, elapsed_ms),
            .verifying_certificate => self.pollCertificate(now_ns),
            .handshaking => self.pollHandshake(now_ns),
            .ready, .failed, .closed => .{ .state = self.state },
        };
    }

    pub fn send(self: *TlsClientRoute, plaintext: []const u8) TlsClientRouteError!TlsClientRouteWrite {
        if (self.state != .ready) return error.InvalidState;
        if (plaintext.len > self.maximum_plaintext_bytes) return error.PayloadTooLarge;
        if (self.write_len != 0) return error.WritePending;
        const encrypted = self.provider.encrypt(plaintext, self.write_buffer) catch |err| {
            self.fail(.write_failed);
            return err;
        };
        self.write_len = encrypted.len;
        self.write_offset = 0;
        return self.flush();
    }

    pub fn flush(self: *TlsClientRoute) TlsClientRouteError!TlsClientRouteWrite {
        if (self.state != .ready) return error.InvalidState;
        const socket = try self.socketHandle();
        var sent_total: usize = 0;
        while (self.write_offset < self.write_len) {
            const sent = std.posix.send(socket, self.write_buffer[self.write_offset..self.write_len], 0) catch |err| switch (err) {
                error.WouldBlock => break,
                else => {
                    self.fail(.write_failed);
                    return error.WriteFailed;
                },
            };
            if (sent == 0) {
                self.fail(.write_failed);
                return error.WriteFailed;
            }
            self.write_offset += sent;
            sent_total += sent;
        }
        const pending = self.write_len - self.write_offset;
        if (pending == 0) {
            self.write_offset = 0;
            self.write_len = 0;
        }
        return .{ .sent_ciphertext_bytes = sent_total, .pending_ciphertext_bytes = pending };
    }

    pub fn receive(self: *TlsClientRoute, ciphertext: []u8, plaintext: []u8) TlsClientRouteError!?[]u8 {
        if (self.state != .ready) return error.InvalidState;
        if (ciphertext.len == 0 or ciphertext.len > self.write_buffer.len or plaintext.len == 0 or plaintext.len > self.maximum_plaintext_bytes) return error.InvalidConfiguration;
        const socket = try self.socketHandle();
        const received = std.posix.recv(socket, ciphertext, 0) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => {
                self.fail(.read_failed);
                return error.ReadFailed;
            },
        };
        if (received == 0) {
            self.fail(.peer_closed);
            return error.ConnectionClosed;
        }
        return self.provider.decrypt(ciphertext[0..received], plaintext) catch |err| {
            self.fail(.read_failed);
            return err;
        };
    }

    pub fn close(self: *TlsClientRoute) void {
        if (self.state == .closed) return;
        self.provider.close();
        self.tcp_sessions.close(self.session) catch {};
        self.state = .closed;
    }

    fn pollTcp(self: *TlsClientRoute, now_ns: core.TimeNs, elapsed_ms: u32) TlsClientRouteError!TlsClientRoutePoll {
        const tcp = try self.tcp_sessions.poll(self.session, elapsed_ms);
        return switch (tcp.outcome) {
            .connecting => .{ .state = .connecting, .tcp_outcome = .connecting },
            .ready => self.beginCertificateVerification(now_ns),
            .refused => self.fail(.tcp_refused),
            .failed => self.fail(.tcp_failed),
            .timed_out => self.fail(.tcp_timed_out),
            .cancelled => self.fail(.tcp_cancelled),
        };
    }

    fn beginCertificateVerification(self: *TlsClientRoute, now_ns: core.TimeNs) TlsClientRouteError!TlsClientRoutePoll {
        const expires_at_ns = std.math.add(core.TimeNs, now_ns, self.handshake_timeout_ns) catch return self.fail(.tls_timeout);
        self.certificate_request_id = try self.certificate_callbacks.begin(.{
            .kind = .client_trust,
            .server_name = self.provider.config.server_name,
            .peer_certificate_chain_id = self.peer_certificate_chain_id,
            .issued_at_ns = now_ns,
            .expires_at_ns = expires_at_ns,
        });
        self.state = .verifying_certificate;
        return .{ .state = .verifying_certificate, .tcp_outcome = .ready };
    }

    fn pollCertificate(self: *TlsClientRoute, now_ns: core.TimeNs) TlsClientRouteError!TlsClientRoutePoll {
        const id = self.certificate_request_id orelse return error.InvalidState;
        const result = self.certificate_callbacks.pollRequest(id, now_ns) orelse return .{ .state = .verifying_certificate };
        self.certificate_request_id = null;
        return switch (result.resolution) {
            .expired => self.fail(.certificate_expired),
            .rejected => self.fail(.certificate_rejected),
            .accepted => |acceptance| switch (acceptance) {
                .client_trust => self.beginHandshake(now_ns),
                .server_identity => self.fail(.certificate_rejected),
            },
        };
    }

    fn beginHandshake(self: *TlsClientRoute, now_ns: core.TimeNs) TlsClientRoutePoll {
        self.provider.start() catch return self.fail(.tls_handshake);
        self.handshake_deadline_ns = std.math.add(core.TimeNs, now_ns, self.handshake_timeout_ns) catch return self.fail(.tls_timeout);
        self.state = .handshaking;
        return .{ .state = .handshaking };
    }

    fn pollHandshake(self: *TlsClientRoute, now_ns: core.TimeNs) TlsClientRoutePoll {
        if (now_ns >= self.handshake_deadline_ns.?) return self.fail(.tls_timeout);
        const work_completed = self.provider.poll(now_ns) catch return self.fail(.tls_handshake);
        return switch (self.provider.state) {
            .handshaking => .{ .state = .handshaking, .tls_work_completed = work_completed },
            .connected => blk: {
                self.state = .ready;
                break :blk .{ .state = .ready, .tls_work_completed = work_completed };
            },
            else => self.fail(.tls_handshake),
        };
    }

    fn socketHandle(self: *TlsClientRoute) TlsClientRouteError!std.posix.socket_t {
        const connection = try self.tcp_sessions.connection(self.session);
        if (connection.state != .connected) return error.InvalidState;
        return (connection.socket orelse return error.ConnectionClosed).handle;
    }

    fn fail(self: *TlsClientRoute, failure: TlsClientRouteFailure) TlsClientRoutePoll {
        if (self.provider.state != .closed) self.provider.close();
        self.tcp_sessions.close(self.session) catch {};
        self.state = .failed;
        return .{ .state = .failed, .failure = failure };
    }
};

pub const TlsClientChannel = struct {
    route: *TlsClientRoute,
    descriptor: channel_delivery.ChannelDescriptor,

    pub fn init(route: *TlsClientRoute, descriptor: channel_delivery.ChannelDescriptor) TlsClientRouteError!TlsClientChannel {
        try descriptor.validate();
        if (descriptor.delivery != .stream or descriptor.maximum_payload_bytes > route.maximum_plaintext_bytes) return error.InvalidConfiguration;
        return .{ .route = route, .descriptor = descriptor };
    }

    pub fn semantics(self: TlsClientChannel) channel_delivery.ChannelSemantics {
        return self.descriptor.semantics();
    }

    pub fn send(self: *TlsClientChannel, payload: []const u8) TlsClientRouteError!TlsClientRouteWrite {
        try self.descriptor.validate_payload(payload.len);
        return self.route.send(payload);
    }

    pub fn poll(self: *TlsClientChannel, ciphertext: []u8, plaintext: []u8) TlsClientRouteError!?[]u8 {
        return self.route.receive(ciphertext, plaintext);
    }
};

test "TLS client routes verify fixture trust then exchange encrypted stream bytes over native TCP" {
    const transport = @import("minna-san-transport");
    const session_registry = @import("session_registry.zig");

    const TrustFixture = struct {
        saw_fixture: bool = false,

        fn begin(context: ?*anyopaque, request: tls_certificate_callback.TlsCertificateRequest) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.saw_fixture = request.kind == .client_trust and request.peer_certificate_chain_id.? == 9 and std.mem.eql(u8, request.server_name, "fixture.test");
        }

        fn poll(_: ?*anyopaque, _: tls_certificate_callback.TlsCertificateRequestId) ?tls_certificate_callback.TlsCertificateResolution {
            return .{ .accepted = .client_trust };
        }
    };
    const FakeProvider = struct {
        polls: usize = 0,
        certificate_checked: bool = false,
        torn_down: bool = false,

        fn certificate(context: ?*anyopaque, name: [*]const u8, name_len: usize) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.certificate_checked = std.mem.eql(u8, name[0..name_len], "fixture.test");
            return @intFromEnum(tls_provider.TlsCertificateDecision.accept);
        }

        fn start(_: ?*anyopaque, _: u8, _: [*]const u8, _: usize, _: [*]const u8, _: usize, certificate_context: ?*anyopaque, callback: ?tls_provider.TlsCertificateCallback) callconv(.c) c_int {
            const name = "fixture.test";
            return callback.?(certificate_context, name.ptr, name.len);
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
    var resources = try resource.ResourceRegistry.init(std.testing.allocator, 2);
    defer resources.deinit();
    var sessions = try session_registry.SessionRegistry.init(std.testing.allocator, &resources, 1);
    defer sessions.deinit();
    var tcp = try tcp_sessions.TcpSessionRegistry.init(std.testing.allocator, &sessions, 1);
    defer tcp.deinit();
    var trust_fixture = TrustFixture{};
    var callbacks = try tls_certificate_callback.TlsCertificateCallbackRegistry.init(std.testing.allocator, .{ .callback = .{ .context = &trust_fixture, .begin = TrustFixture.begin, .poll = TrustFixture.poll }, .maximum_pending = 1, .maximum_server_identities = 1, .failure_event_capacity = 1 });
    defer callbacks.deinit();
    const session = try tcp.dial(.{ .endpoint = transport.Endpoint.from_ipv4(endpoint), .family_policy = .ipv4_only, .platform_support = .{ .ipv4 = true, .ipv6 = false, .dual_stack = false }, .timeout_ms = 1_000 });
    var fake = FakeProvider{};
    var route = try TlsClientRoute.init(std.testing.allocator, .{ .tcp_sessions = &tcp, .session = session, .provider = try tls_provider.TlsProvider.init(.{ .role = .client, .alpn = "fixture", .server_name = "fixture.test", .certificate_context = &fake, .certificate_callback = FakeProvider.certificate }, &fake, .{ .start = FakeProvider.start, .poll = FakeProvider.poll, .encrypt = FakeProvider.encrypt, .decrypt = FakeProvider.decrypt, .teardown = FakeProvider.teardown }), .certificate_callbacks = &callbacks, .peer_certificate_chain_id = 9, .handshake_timeout_ns = 100, .maximum_plaintext_bytes = 32, .maximum_ciphertext_bytes = 64 });
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
    try std.testing.expectEqual(TlsClientRouteState.ready, route.state);
    try std.testing.expect(trust_fixture.saw_fixture and fake.certificate_checked);
    var channel = try TlsClientChannel.init(&route, .{ .delivery = .stream, .maximum_payload_bytes = 32 });
    const write = try channel.send("request");
    try std.testing.expectEqual(@as(usize, 0), write.pending_ciphertext_bytes);
    var encrypted: [64]u8 = undefined;
    const server_socket = (server_connection.socket orelse return error.TestExpectedEqual).handle;
    var received: usize = 0;
    while (received == 0) received = std.posix.recv(server_socket, encrypted[0..], 0) catch |err| switch (err) {
        error.WouldBlock => {
            std.Thread.sleep(std.time.ns_per_ms);
            continue;
        },
        else => return err,
    };
    try std.testing.expectEqualStrings("\xa5request", encrypted[0..received]);
    _ = try std.posix.send(server_socket, encrypted[0..received], 0);
    var ciphertext: [64]u8 = undefined;
    var plaintext: [32]u8 = undefined;
    var response: ?[]u8 = null;
    var attempts: usize = 0;
    while (response == null and attempts < 100) : (attempts += 1) {
        response = try channel.poll(ciphertext[0..], plaintext[0..]);
        if (response == null) std.Thread.sleep(std.time.ns_per_ms);
    }
    try std.testing.expectEqualStrings("request", response orelse return error.TestExpectedEqual);
    route.close();
    try std.testing.expect(fake.torn_down);
}
