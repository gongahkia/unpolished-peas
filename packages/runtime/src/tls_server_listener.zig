const std = @import("std");
const core = @import("minna-san-core");
const resource = @import("resource_handle.zig");
const tcp_listeners = @import("tcp_listener_registry.zig");
const tcp_sessions = @import("tcp_session_registry.zig");
const tls_callbacks = @import("tls_certificate_callback.zig");
const tls_provider = @import("tls_provider.zig");

pub const max_tls_server_connections: usize = 64;
pub const TlsServerConnectionState = enum { verifying_certificate, handshaking, ready, rejected, closed };
pub const TlsServerConnectionFailure = enum { certificate_rejected, certificate_expired, provider_factory, handshake, handshake_timeout };
pub const TlsServerListenerError = std.mem.Allocator.Error || tcp_listeners.TcpListenerRegistryError || tcp_sessions.TcpSessionRegistryError || tls_callbacks.TlsCertificateCallbackError || tls_provider.TlsProviderError || error{ InvalidConfiguration, ConnectionLimitExceeded, UnknownConnection, TimeOverflow };
pub const TlsServerProviderFactoryFn = *const fn (context: ?*anyopaque, identity: tls_callbacks.TlsServerIdentity, server_name: []const u8) ?tls_provider.TlsProvider;
pub const TlsServerProviderFactory = struct { context: ?*anyopaque = null, create: TlsServerProviderFactoryFn };
pub const TlsServerListenerConfig = struct {
    tcp_listeners: *tcp_listeners.TcpListenerRegistry,
    tcp_sessions: *tcp_sessions.TcpSessionRegistry,
    listener: *resource.ResourceHandle,
    certificate_callbacks: *tls_callbacks.TlsCertificateCallbackRegistry,
    provider_factory: TlsServerProviderFactory,
    maximum_connections: usize = max_tls_server_connections,
    handshake_timeout_ns: core.TimeNs,

    pub fn validate(self: TlsServerListenerConfig) TlsServerListenerError!void {
        if (self.maximum_connections == 0 or self.maximum_connections > max_tls_server_connections or self.handshake_timeout_ns == 0) return error.InvalidConfiguration;
    }
};
pub const TlsServerConnectionPoll = struct {
    session: *resource.ResourceHandle,
    state: TlsServerConnectionState,
    work_completed: usize = 0,
    identity: ?tls_callbacks.TlsServerIdentity = null,
    failure: ?TlsServerConnectionFailure = null,
};

const Entry = struct {
    session: *resource.ResourceHandle,
    server_name: [tls_callbacks.max_tls_server_name_bytes]u8 = undefined,
    server_name_len: usize,
    request: tls_callbacks.TlsCertificateRequestId,
    deadline_ns: core.TimeNs,
    provider: ?tls_provider.TlsProvider = null,
    identity: ?tls_callbacks.TlsServerIdentity = null,
    state: TlsServerConnectionState = .verifying_certificate,
};

pub const TlsServerListener = struct {
    allocator: std.mem.Allocator,
    config: TlsServerListenerConfig,
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator, config: TlsServerListenerConfig) TlsServerListenerError!TlsServerListener {
        try config.validate();
        _ = try config.tcp_listeners.localAddress(config.listener);
        return .{ .allocator = allocator, .config = config };
    }

    pub fn deinit(self: *TlsServerListener) void {
        for (self.entries.items) |*entry| self.closeEntry(entry);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn accept(self: *TlsServerListener, server_name: []const u8, now_ns: core.TimeNs) TlsServerListenerError!?*resource.ResourceHandle {
        if (server_name.len > tls_callbacks.max_tls_server_name_bytes) return error.InvalidConfiguration;
        const accepted = try self.config.tcp_listeners.accept(self.config.listener) orelse return null;
        if (self.entries.items.len == self.config.maximum_connections) {
            var connection = accepted.connection;
            connection.close();
            return error.ConnectionLimitExceeded;
        }
        var connection = accepted.connection;
        const session = try self.config.tcp_sessions.adopt(&connection, accepted.peer);
        errdefer self.config.tcp_sessions.close(session) catch {};
        const deadline_ns = std.math.add(core.TimeNs, now_ns, self.config.handshake_timeout_ns) catch return error.TimeOverflow;
        const request = try self.config.certificate_callbacks.begin(.{ .kind = .server_identity, .server_name = server_name, .issued_at_ns = now_ns, .expires_at_ns = deadline_ns });
        var entry = Entry{ .session = session, .server_name_len = server_name.len, .request = request, .deadline_ns = deadline_ns };
        @memcpy(entry.server_name[0..server_name.len], server_name);
        try self.entries.append(self.allocator, entry);
        return session;
    }

    pub fn poll(self: *TlsServerListener, session: *resource.ResourceHandle, now_ns: core.TimeNs) TlsServerListenerError!TlsServerConnectionPoll {
        const entry = try self.lookup(session);
        return switch (entry.state) {
            .verifying_certificate => self.pollCertificate(entry, now_ns),
            .handshaking => self.pollHandshake(entry, now_ns),
            .ready, .rejected, .closed => .{ .session = entry.session, .state = entry.state, .identity = entry.identity },
        };
    }

    pub fn close(self: *TlsServerListener, session: *resource.ResourceHandle) TlsServerListenerError!void {
        for (self.entries.items, 0..) |entry, index| {
            if (entry.session != session) continue;
            var removed = self.entries.orderedRemove(index);
            self.closeEntry(&removed);
            return;
        }
        return error.UnknownConnection;
    }

    fn pollCertificate(self: *TlsServerListener, entry: *Entry, now_ns: core.TimeNs) TlsServerListenerError!TlsServerConnectionPoll {
        const result = self.config.certificate_callbacks.pollRequest(entry.request, now_ns) orelse return .{ .session = entry.session, .state = .verifying_certificate };
        return switch (result.resolution) {
            .expired => self.fail(entry, .certificate_expired),
            .rejected => self.fail(entry, .certificate_rejected),
            .accepted => |acceptance| switch (acceptance) {
                .client_trust => self.fail(entry, .certificate_rejected),
                .server_identity => |identity| {
                    const provider = self.config.provider_factory.create(self.config.provider_factory.context, identity, entry.server_name[0..entry.server_name_len]) orelse return self.fail(entry, .provider_factory);
                    entry.provider = provider;
                    entry.identity = identity;
                    entry.provider.?.start() catch return self.fail(entry, .handshake);
                    entry.state = .handshaking;
                    return .{ .session = entry.session, .state = .handshaking, .identity = identity };
                },
            },
        };
    }

    fn pollHandshake(self: *TlsServerListener, entry: *Entry, now_ns: core.TimeNs) TlsServerConnectionPoll {
        if (now_ns >= entry.deadline_ns) return self.fail(entry, .handshake_timeout);
        const provider = &(entry.provider orelse return self.fail(entry, .provider_factory));
        const work_completed = provider.poll(now_ns) catch return self.fail(entry, .handshake);
        if (provider.state == .connected) {
            entry.state = .ready;
            return .{ .session = entry.session, .state = .ready, .work_completed = work_completed, .identity = entry.identity };
        }
        return if (provider.state == .handshaking) .{ .session = entry.session, .state = .handshaking, .work_completed = work_completed, .identity = entry.identity } else self.fail(entry, .handshake);
    }

    fn fail(self: *TlsServerListener, entry: *Entry, failure: TlsServerConnectionFailure) TlsServerConnectionPoll {
        if (entry.provider) |*provider| provider.close();
        self.config.tcp_sessions.close(entry.session) catch {};
        entry.state = .rejected;
        return .{ .session = entry.session, .state = .rejected, .identity = entry.identity, .failure = failure };
    }

    fn closeEntry(self: *TlsServerListener, entry: *Entry) void {
        if (entry.provider) |*provider| provider.close();
        self.config.tcp_sessions.close(entry.session) catch {};
        entry.state = .closed;
    }

    fn lookup(self: *TlsServerListener, session: *resource.ResourceHandle) TlsServerListenerError!*Entry {
        for (self.entries.items) |*entry| if (entry.session == session) return entry;
        return error.UnknownConnection;
    }
};

test "TLS server listeners select distinct SNI fixture identities without listener restart" {
    const transport = @import("minna-san-transport");
    const session_registry = @import("session_registry.zig");
    const Fixture = struct {
        one: tls_callbacks.TlsCertificateRequestId = 0,
        two: tls_callbacks.TlsCertificateRequestId = 0,

        fn begin(context: ?*anyopaque, request: tls_callbacks.TlsCertificateRequest) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (std.mem.eql(u8, request.server_name, "one.test")) self.one = request.id else if (std.mem.eql(u8, request.server_name, "two.test")) self.two = request.id;
        }

        fn poll(context: ?*anyopaque, id: tls_callbacks.TlsCertificateRequestId) ?tls_callbacks.TlsCertificateResolution {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            const certificate_chain_id: u64 = if (id == self.one) 101 else if (id == self.two) 202 else return .{ .rejected = .unrecognized_name };
            return .{ .accepted = .{ .server_identity = .{ .certificate_chain_id = certificate_chain_id, .private_key_id = certificate_chain_id, .not_before_ns = 0, .not_after_ns = 100, .generation = certificate_chain_id } } };
        }
        fn start(_: ?*anyopaque, _: u8, _: [*]const u8, _: usize, _: [*]const u8, _: usize, _: ?*anyopaque, _: ?tls_provider.TlsCertificateCallback) callconv(.c) c_int {
            return @intFromEnum(core.CResult.ok);
        }
        fn pollProvider(_: ?*anyopaque, _: core.TimeNs, output: *tls_provider.TlsPollOutput) callconv(.c) c_int {
            output.* = .{ .state = @intFromEnum(tls_provider.TlsState.connected), .work_completed = 1 };
            return @intFromEnum(core.CResult.ok);
        }
        fn io(_: ?*anyopaque, _: [*]const u8, _: usize, _: [*]u8, _: usize, _: *tls_provider.TlsIoOutput) callconv(.c) c_int {
            return @intFromEnum(core.CResult.ok);
        }
        fn receiveRecord(_: ?*anyopaque, _: [*]const u8, input_len: usize, result: *tls_provider.TlsRecordOutput) callconv(.c) c_int {
            result.* = .{ .bytes = input_len };
            return @intFromEnum(core.CResult.ok);
        }
        fn drainRecord(_: ?*anyopaque, _: [*]u8, _: usize, result: *tls_provider.TlsRecordOutput) callconv(.c) c_int {
            result.* = .{};
            return @intFromEnum(core.CResult.ok);
        }
        fn teardown(_: ?*anyopaque) callconv(.c) void {}
        fn create(_: ?*anyopaque, _: tls_callbacks.TlsServerIdentity, name: []const u8) ?tls_provider.TlsProvider {
            return tls_provider.TlsProvider.init(.{ .role = .server, .alpn = "http/1.1", .server_name = name }, null, .{ .start = start, .poll = pollProvider, .encrypt = io, .decrypt = io, .receive_record = receiveRecord, .drain_record = drainRecord, .teardown = teardown }) catch null;
        }
    };
    var resources = try resource.ResourceRegistry.init(std.testing.allocator, 4);
    defer resources.deinit();
    var sessions = try session_registry.SessionRegistry.init(std.testing.allocator, &resources, 2);
    defer sessions.deinit();
    var tcp = try tcp_sessions.TcpSessionRegistry.init(std.testing.allocator, &sessions, 2);
    defer tcp.deinit();
    var listeners = try tcp_listeners.TcpListenerRegistry.init(std.testing.allocator, &resources, 1);
    defer listeners.deinit();
    const listener = try listeners.open(.{ .endpoint = transport.Ipv4Address.wildcard(0), .backlog = 2 });
    const endpoint = try transport.Ipv4Address.parse("127.0.0.1", (try listeners.localAddress(listener)).port);
    var fixture = Fixture{};
    var callbacks = try tls_callbacks.TlsCertificateCallbackRegistry.init(std.testing.allocator, .{ .callback = .{ .context = &fixture, .begin = Fixture.begin, .poll = Fixture.poll }, .maximum_pending = 2, .maximum_server_identities = 2, .failure_event_capacity = 2 });
    defer callbacks.deinit();
    var server = try TlsServerListener.init(std.testing.allocator, .{ .tcp_listeners = &listeners, .tcp_sessions = &tcp, .listener = listener, .certificate_callbacks = &callbacks, .provider_factory = .{ .create = Fixture.create }, .maximum_connections = 2, .handshake_timeout_ns = 10 });
    defer server.deinit();
    var first = try transport.TcpConnection.init();
    defer if (first.state != .closed) first.close();
    var second = try transport.TcpConnection.init();
    defer if (second.state != .closed) second.close();
    _ = try first.start_connect(endpoint, 1_000);
    _ = try second.start_connect(endpoint, 1_000);
    var accepted: [2]?*resource.ResourceHandle = .{ null, null };
    var attempts: usize = 0;
    while ((accepted[0] == null or accepted[1] == null) and attempts < 100) : (attempts += 1) {
        if (accepted[0] == null) accepted[0] = try server.accept("one.test", 0);
        if (accepted[1] == null) accepted[1] = try server.accept("two.test", 0);
        std.Thread.sleep(std.time.ns_per_ms);
    }
    const one = accepted[0] orelse return error.TestExpectedEqual;
    const two = accepted[1] orelse return error.TestExpectedEqual;
    _ = try server.poll(one, 1);
    _ = try server.poll(two, 1);
    const first_ready = try server.poll(one, 2);
    const second_ready = try server.poll(two, 2);
    try std.testing.expectEqual(TlsServerConnectionState.ready, first_ready.state);
    try std.testing.expectEqual(TlsServerConnectionState.ready, second_ready.state);
    try std.testing.expectEqual(@as(u64, 101), first_ready.identity.?.certificate_chain_id);
    try std.testing.expectEqual(@as(u64, 202), second_ready.identity.?.certificate_chain_id);
    try server.close(one);
    try server.close(two);
}
