const std = @import("std");
const core = @import("minna-san-core");
const protocol = @import("minna-san-protocol");
const topology = @import("minna-san-topology");
const transport = @import("minna-san-transport");
const provider = @import("provider.zig");

pub const max_tcp_stun_binding_requests: usize = core.max_session_capacity;
pub const max_tcp_stun_binding_frame_bytes: usize = 4096;
pub const max_tcp_stun_binding_request_bytes: usize = protocol.stun_header_bytes + 4 + std.mem.alignForward(usize, protocol.max_stun_credential_bytes, 4) + 4 + protocol.stun_integrity_tag_bytes;

pub const TcpStunBindingProviderError = std.mem.Allocator.Error || provider.ProviderError || transport.TcpConnectionError || topology.TcpStunBindingError || protocol.StunCodecError || protocol.StunCredentialError || error{ InvalidConfiguration, Inactive, RequestCapacityExceeded, StaleRequest, NotReady, Cancelled, BindingFailed, FrameInProgress, MessageTooLarge, ConnectionClosed, ReadFailed, WriteFailed, MalformedFrame };

pub const TcpStunBindingProviderConfig = struct {
    maximum_requests: usize = 64,
    poll_work_budget: usize = 1,

    pub fn validate(self: TcpStunBindingProviderConfig) TcpStunBindingProviderError!void {
        if (self.maximum_requests == 0 or self.maximum_requests > max_tcp_stun_binding_requests or self.poll_work_budget == 0 or self.poll_work_budget > core.max_poll_work_budget) return error.InvalidConfiguration;
    }
};

pub const TcpStunBindingRequestConfig = struct {
    server: transport.Ipv4Address,
    timeout_ns: core.TimeNs,
    credentials: ?protocol.StunShortTermCredentials = null,

    pub fn validate(self: TcpStunBindingRequestConfig) TcpStunBindingProviderError!void {
        const timeout_ms = std.math.divCeil(core.TimeNs, self.timeout_ns, std.time.ns_per_ms) catch return error.InvalidConfiguration;
        if (self.server.port == 0 or self.timeout_ns == 0 or timeout_ms == 0 or timeout_ms > std.math.maxInt(u32)) return error.InvalidConfiguration;
        if (self.credentials) |credentials| try protocol.validate_short_term_credentials(credentials);
    }
};

pub const TcpStunBindingRequestHandle = struct {
    provider_id: u32,
    slot: u32,
    generation: u32,
};

pub const TcpStunBindingRequestState = enum { pending, mapped, failed, cancelled };

const OwnedCredentials = struct {
    username: [protocol.max_stun_credential_bytes]u8 = [_]u8{0} ** protocol.max_stun_credential_bytes,
    username_len: usize = 0,
    password: [protocol.max_stun_credential_bytes]u8 = [_]u8{0} ** protocol.max_stun_credential_bytes,
    password_len: usize = 0,

    fn init(input: ?protocol.StunShortTermCredentials) protocol.StunCredentialError!OwnedCredentials {
        const credentials = input orelse return .{};
        try protocol.validate_short_term_credentials(credentials);
        var result = OwnedCredentials{ .username_len = credentials.username.len, .password_len = credentials.password.len };
        @memcpy(result.username[0..result.username_len], credentials.username);
        @memcpy(result.password[0..result.password_len], credentials.password);
        return result;
    }

    fn value(self: *const OwnedCredentials) ?protocol.StunShortTermCredentials {
        if (self.username_len == 0) return null;
        return .{ .username = self.username[0..self.username_len], .password = self.password[0..self.password_len] };
    }

    fn deinit(self: *OwnedCredentials) void {
        std.crypto.secureZero(u8, &self.username);
        std.crypto.secureZero(u8, &self.password);
        self.username_len = 0;
        self.password_len = 0;
    }
};

const StunFrameReader = struct {
    storage: []u8,
    header: [2]u8 = undefined,
    header_used: usize = 0,
    body_length: ?usize = null,
    body_used: usize = 0,
    failed: bool = false,

    fn init(storage: []u8) TcpStunBindingProviderError!StunFrameReader {
        if (storage.len < protocol.stun_header_bytes or storage.len > std.math.maxInt(u16)) return error.InvalidConfiguration;
        return .{ .storage = storage };
    }

    fn read(self: *StunFrameReader, connection: *transport.TcpConnection) TcpStunBindingProviderError!?[]u8 {
        if (self.failed) return error.MalformedFrame;
        const handle = connectionHandle(connection) orelse return error.ConnectionClosed;
        while (true) {
            if (self.body_length) |length| {
                const received = std.posix.recv(handle, self.storage[self.body_used..length], 0) catch |err| switch (err) {
                    error.WouldBlock => return null,
                    else => return error.ReadFailed,
                };
                if (received == 0) return error.ConnectionClosed;
                self.body_used += received;
                if (self.body_used == length) {
                    const frame = self.storage[0..length];
                    self.reset();
                    return frame;
                }
                continue;
            }
            const received = std.posix.recv(handle, self.header[self.header_used..], 0) catch |err| switch (err) {
                error.WouldBlock => return null,
                else => return error.ReadFailed,
            };
            if (received == 0) return error.ConnectionClosed;
            self.header_used += received;
            if (self.header_used != self.header.len) continue;
            const length: usize = std.mem.readInt(u16, self.header[0..], .big);
            if (length < protocol.stun_header_bytes or length > self.storage.len) {
                self.failed = true;
                return error.MalformedFrame;
            }
            self.body_length = length;
        }
    }

    fn reset(self: *StunFrameReader) void {
        self.header_used = 0;
        self.body_length = null;
        self.body_used = 0;
    }
};

const StunFrameWriter = struct {
    header: [2]u8 = undefined,
    header_sent: usize = 0,
    payload: ?[]const u8 = null,
    payload_sent: usize = 0,

    fn begin(self: *StunFrameWriter, payload: []const u8) TcpStunBindingProviderError!void {
        if (self.payload != null) return error.FrameInProgress;
        if (payload.len > std.math.maxInt(u16)) return error.MessageTooLarge;
        std.mem.writeInt(u16, self.header[0..], @intCast(payload.len), .big);
        self.payload = payload;
        self.header_sent = 0;
        self.payload_sent = 0;
    }

    fn flush(self: *StunFrameWriter, connection: *transport.TcpConnection) TcpStunBindingProviderError!bool {
        const handle = connectionHandle(connection) orelse return error.ConnectionClosed;
        const payload = self.payload orelse return error.NotReady;
        while (self.header_sent < self.header.len) {
            const sent = std.posix.send(handle, self.header[self.header_sent..], 0) catch |err| switch (err) {
                error.WouldBlock => return false,
                else => return error.WriteFailed,
            };
            if (sent == 0) return error.WriteFailed;
            self.header_sent += sent;
        }
        while (self.payload_sent < payload.len) {
            const sent = std.posix.send(handle, payload[self.payload_sent..], 0) catch |err| switch (err) {
                error.WouldBlock => return false,
                else => return error.WriteFailed,
            };
            if (sent == 0) return error.WriteFailed;
            self.payload_sent += sent;
        }
        self.payload = null;
        self.header_sent = 0;
        self.payload_sent = 0;
        return true;
    }
};

const RequestPhase = enum { connecting, preparing, sending, waiting };

const Request = struct {
    connection: transport.TcpConnection,
    client: topology.TcpStunBindingClient,
    credentials: OwnedCredentials,
    started_ns: core.TimeNs,
    outbound: [max_tcp_stun_binding_request_bytes]u8 = undefined,
    writer: StunFrameWriter = .{},
    inbound: [max_tcp_stun_binding_frame_bytes]u8 = undefined,
    reader: StunFrameReader,
    phase: RequestPhase,
    state: TcpStunBindingRequestState = .pending,
    result: ?protocol.StunAddress = null,

    fn closeConnection(self: *Request) void {
        if (self.connection.socket != null) self.connection.close();
    }

    fn deinit(self: *Request) void {
        self.closeConnection();
        self.credentials.deinit();
        self.* = undefined;
    }
};

const Slot = struct {
    generation: u32 = 1,
    request: ?*Request = null,
};

var next_provider_id = std.atomic.Value(u32).init(1);

pub const TcpStunBindingProvider = struct {
    allocator: std.mem.Allocator,
    config: TcpStunBindingProviderConfig,
    provider_id: u32,
    slots: []Slot,
    next_slot: usize = 0,
    active: bool = false,

    pub fn init(allocator: std.mem.Allocator, config: TcpStunBindingProviderConfig) TcpStunBindingProviderError!TcpStunBindingProvider {
        try config.validate();
        const provider_id = next_provider_id.fetchAdd(1, .monotonic);
        if (provider_id == 0) return error.InvalidConfiguration;
        const slots = try allocator.alloc(Slot, config.maximum_requests);
        for (slots) |*slot| slot.* = .{};
        return .{ .allocator = allocator, .config = config, .provider_id = provider_id, .slots = slots };
    }

    pub fn deinit(self: *TcpStunBindingProvider) void {
        for (self.slots, 0..) |slot, index| if (slot.request != null) self.destroyRequest(index);
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    pub fn asProvider(self: *TcpStunBindingProvider) provider.ProviderError!provider.Provider {
        return provider.Provider.init(.{ .name = "tcp-stun", .poll_work_budget = self.config.poll_work_budget }, self, .{ .init = providerInit, .query_capabilities = queryCapabilities, .poll = providerPoll, .teardown = providerTeardown });
    }

    pub fn startBinding(self: *TcpStunBindingProvider, config_value: TcpStunBindingRequestConfig) TcpStunBindingProviderError!TcpStunBindingRequestHandle {
        if (!self.active) return error.Inactive;
        try config_value.validate();
        const index = self.freeSlot() orelse return error.RequestCapacityExceeded;
        var connection = try transport.TcpConnection.init();
        var connection_owned = true;
        errdefer if (connection_owned) connection.close();
        const connection_state = connection.start_connect(config_value.server, timeoutMs(config_value.timeout_ns)) catch |err| switch (err) {
            error.ConnectionRefused => transport.TcpConnectionState.failed,
            else => return err,
        };
        var credentials = try OwnedCredentials.init(config_value.credentials);
        var credentials_owned = true;
        errdefer if (credentials_owned) credentials.deinit();
        const request = try self.allocator.create(Request);
        var request_owned = true;
        errdefer if (request_owned) self.allocator.destroy(request);
        request.* = .{
            .connection = connection,
            .client = undefined,
            .credentials = credentials,
            .started_ns = 0,
            .reader = undefined,
            .phase = if (connection_state == .failed) .connecting else if (connection_state == .connected) .preparing else .connecting,
            .state = if (connection_state == .failed) .failed else .pending,
        };
        connection_owned = false;
        credentials_owned = false;
        errdefer if (request_owned) request.deinit();
        request.reader = try StunFrameReader.init(request.inbound[0..]);
        var transaction_id: [12]u8 = undefined;
        std.crypto.random.bytes(&transaction_id);
        request.client = try topology.TcpStunBindingClient.init(.{ .server = config_value.server, .timeout_ns = config_value.timeout_ns, .credentials = request.credentials.value() }, transaction_id);
        self.slots[index].request = request;
        request_owned = false;
        return .{ .provider_id = self.provider_id, .slot = @intCast(index), .generation = self.slots[index].generation };
    }

    pub fn refreshBinding(self: *TcpStunBindingProvider, handle: TcpStunBindingRequestHandle) TcpStunBindingProviderError!void {
        const request = try self.lookupRequest(handle);
        if (request.state != .mapped or request.connection.state != .connected) return error.NotReady;
        var transaction_id: [12]u8 = undefined;
        std.crypto.random.bytes(&transaction_id);
        request.client = try topology.TcpStunBindingClient.init(.{ .server = request.client.config.server, .timeout_ns = request.client.config.timeout_ns, .credentials = request.credentials.value() }, transaction_id);
        request.writer = .{};
        request.reader.reset();
        request.state = .pending;
        request.result = null;
        request.phase = .preparing;
    }

    pub fn state(self: *TcpStunBindingProvider, handle: TcpStunBindingRequestHandle) TcpStunBindingProviderError!TcpStunBindingRequestState {
        return (try self.lookupRequest(handle)).state;
    }

    pub fn result(self: *TcpStunBindingProvider, handle: TcpStunBindingRequestHandle) TcpStunBindingProviderError!protocol.StunAddress {
        const request = try self.lookupRequest(handle);
        return switch (request.state) {
            .pending => error.NotReady,
            .mapped => request.result orelse error.BindingFailed,
            .failed => error.BindingFailed,
            .cancelled => error.Cancelled,
        };
    }

    pub fn cancel(self: *TcpStunBindingProvider, handle: TcpStunBindingRequestHandle) TcpStunBindingProviderError!void {
        const request = try self.lookupRequest(handle);
        if (request.state != .pending) return error.NotReady;
        request.closeConnection();
        request.state = .cancelled;
    }

    pub fn release(self: *TcpStunBindingProvider, handle: TcpStunBindingRequestHandle) TcpStunBindingProviderError!void {
        const request = try self.lookupRequest(handle);
        if (request.state == .pending) return error.NotReady;
        self.destroyRequest(handle.slot);
    }

    fn poll(self: *TcpStunBindingProvider, now_ns: core.TimeNs, work_budget: usize) provider.ProviderPollResult {
        var poll_result = provider.ProviderPollResult{};
        var inspected: usize = 0;
        while (inspected < work_budget) : (inspected += 1) {
            const index = self.next_slot;
            self.next_slot = (self.next_slot + 1) % self.slots.len;
            const request = self.slots[index].request orelse continue;
            if (request.state != .pending) continue;
            if (self.pollRequest(request, now_ns)) poll_result.work_completed += 1;
            if (request.state != .pending) continue;
            const deadline = request.client.deadline_ns orelse request.started_ns +| request.client.config.timeout_ns;
            poll_result.next_deadline = if (poll_result.next_deadline) |current| @min(current, deadline) else deadline;
        }
        return poll_result;
    }

    fn pollRequest(self: *TcpStunBindingProvider, request: *Request, now_ns: core.TimeNs) bool {
        if (request.phase != .connecting and request.client.deadline_ns != null) request.client.poll(now_ns) catch {
            self.failRequest(request);
            return true;
        };
        switch (request.phase) {
            .connecting => {
                if (request.started_ns == 0) request.started_ns = now_ns;
                const connection_state = request.connection.complete(elapsedMs(now_ns, request.started_ns)) catch {
                    self.failRequest(request);
                    return true;
                };
                if (connection_state == .connecting) return false;
                request.phase = .preparing;
                return true;
            },
            .preparing => {
                const frame = request.client.begin(now_ns, request.outbound[0..]) catch {
                    self.failRequest(request);
                    return true;
                };
                request.writer.begin(frame) catch {
                    self.failRequest(request);
                    return true;
                };
                request.phase = .sending;
                return true;
            },
            .sending => {
                const sent = request.writer.flush(&request.connection) catch {
                    self.failRequest(request);
                    return true;
                };
                if (!sent) return false;
                request.phase = .waiting;
                return true;
            },
            .waiting => {
                const frame = request.reader.read(&request.connection) catch {
                    self.failRequest(request);
                    return true;
                } orelse return false;
                var attributes: [16]protocol.StunAttribute = undefined;
                const mapped = request.client.receive_frame(now_ns, frame, attributes[0..]) catch {
                    self.failRequest(request);
                    return true;
                };
                request.result = mapped;
                request.state = .mapped;
                return true;
            },
        }
    }

    fn failRequest(_: *TcpStunBindingProvider, request: *Request) void {
        request.closeConnection();
        request.state = .failed;
    }

    fn lookupRequest(self: *TcpStunBindingProvider, handle: TcpStunBindingRequestHandle) TcpStunBindingProviderError!*Request {
        if (handle.provider_id != self.provider_id or handle.slot >= self.slots.len) return error.StaleRequest;
        const slot = &self.slots[handle.slot];
        if (slot.generation != handle.generation) return error.StaleRequest;
        return slot.request orelse error.StaleRequest;
    }

    fn freeSlot(self: *const TcpStunBindingProvider) ?usize {
        for (self.slots, 0..) |slot, index| if (slot.request == null) return index;
        return null;
    }

    fn destroyRequest(self: *TcpStunBindingProvider, index: usize) void {
        const slot = &self.slots[index];
        const request = slot.request orelse return;
        request.deinit();
        self.allocator.destroy(request);
        slot.request = null;
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
    }

    fn providerInit(context: ?*anyopaque) callconv(.c) c_int {
        const self: *TcpStunBindingProvider = @ptrCast(@alignCast(context orelse return @intFromEnum(core.CResult.invalid_argument)));
        if (self.active) return @intFromEnum(core.CResult.invalid_state);
        self.active = true;
        return @intFromEnum(core.CResult.ok);
    }

    fn queryCapabilities(context: ?*anyopaque, out_capabilities: *provider.ProviderCapabilityDescriptor) callconv(.c) c_int {
        _ = context;
        out_capabilities.* = .{ .transport_bits = core.transport_capability_bit(.tcp), .protocol_bits = core.protocol_capability_bit(.stun) };
        return @intFromEnum(core.CResult.ok);
    }

    fn providerPoll(context: ?*anyopaque, now_ns: core.TimeNs, work_budget: usize, out_result: *provider.ProviderPollOutput) callconv(.c) c_int {
        const self: *TcpStunBindingProvider = @ptrCast(@alignCast(context orelse return @intFromEnum(core.CResult.invalid_argument)));
        if (!self.active) return @intFromEnum(core.CResult.invalid_state);
        const poll_result = self.poll(now_ns, work_budget);
        out_result.* = .{ .work_completed = poll_result.work_completed, .next_deadline_ns = poll_result.next_deadline orelse 0, .has_next_deadline = if (poll_result.next_deadline != null) 1 else 0 };
        return @intFromEnum(core.CResult.ok);
    }

    fn providerTeardown(context: ?*anyopaque) callconv(.c) void {
        const self: *TcpStunBindingProvider = @ptrCast(@alignCast(context orelse return));
        self.active = false;
        for (self.slots) |slot| {
            const request = slot.request orelse continue;
            request.closeConnection();
            if (request.state == .pending) request.state = .cancelled;
        }
    }
};

fn connectionHandle(connection: *transport.TcpConnection) ?std.posix.socket_t {
    if (connection.state != .connected) return null;
    const socket = connection.socket orelse return null;
    return socket.handle;
}

fn timeoutMs(timeout_ns: core.TimeNs) u32 {
    return @intCast(@max(@as(core.TimeNs, 1), std.math.divCeil(core.TimeNs, timeout_ns, std.time.ns_per_ms) catch unreachable));
}

fn elapsedMs(now_ns: core.TimeNs, started_ns: core.TimeNs) u32 {
    return @intCast(@min((now_ns -| started_ns) / std.time.ns_per_ms, std.math.maxInt(u32)));
}

fn verifyFrameIntegrity(credentials: protocol.StunShortTermCredentials, frame: []const u8) !void {
    var offset: usize = protocol.stun_header_bytes;
    while (offset < frame.len) {
        const kind = std.mem.readInt(u16, frame[offset..][0..2], .big);
        const value_len: usize = std.mem.readInt(u16, frame[offset + 2 ..][0..2], .big);
        const value_offset = offset + 4;
        if (kind == 0x001c) {
            if (value_len != protocol.stun_integrity_tag_bytes) return error.IntegrityMismatch;
            var received: [protocol.stun_integrity_tag_bytes]u8 = undefined;
            @memcpy(&received, frame[value_offset..][0..protocol.stun_integrity_tag_bytes]);
            var header = frame[0..protocol.stun_header_bytes].*;
            std.mem.writeInt(u16, header[2..4], @intCast(value_offset + protocol.stun_integrity_tag_bytes - protocol.stun_header_bytes), .big);
            var context = std.crypto.auth.hmac.sha2.HmacSha256.init(credentials.password);
            context.update(&header);
            context.update(frame[protocol.stun_header_bytes..value_offset]);
            var expected: [protocol.stun_integrity_tag_bytes]u8 = undefined;
            context.final(&expected);
            defer std.crypto.secureZero(u8, &expected);
            return protocol.verify_stun_integrity(frame, expected, received);
        }
        offset += 4 + std.mem.alignForward(usize, value_len, 4);
    }
    return error.IntegrityMismatch;
}

fn encodeBindingResponse(transaction_id: [12]u8, mapped: protocol.StunAddress, credentials: protocol.StunShortTermCredentials, output: []u8) ![]u8 {
    var address: [20]u8 = undefined;
    const mapped_value = try protocol.encode_xor_address(mapped, transaction_id, address[0..]);
    var integrity = [_]u8{0} ** protocol.stun_integrity_tag_bytes;
    const attributes = [_]protocol.StunAttribute{ .{ .kind = 0x0020, .value = mapped_value }, .{ .kind = 0x001c, .value = integrity[0..] } };
    const encoded = try protocol.encode_stun_message(.{ .method = 1, .class = .success_response, .transaction_id = transaction_id }, attributes[0..], output);
    const integrity_offset = protocol.stun_header_bytes + 4 + std.mem.alignForward(usize, mapped_value.len, 4) + 4;
    const expected = try protocol.stun_short_term_integrity(credentials, encoded[0..integrity_offset]);
    @memcpy(encoded[integrity_offset..][0..protocol.stun_integrity_tag_bytes], &expected);
    return encoded;
}

test "runtime TCP STUN providers poll credentialed loopback bindings and reuse connections" {
    var manual = core.ManualClock.init(0);
    const sdk = try @import("sdk_config.zig").SdkConfigBuilder.init().with_clock(manual.clock()).with_platform_config(.{ .limits = .{ .provider_capacity = 1, .poll_work_budget = 1 } }).build();
    var runtime = try @import("platform_runtime.zig").Runtime.init(std.testing.allocator, sdk);
    var binding = try TcpStunBindingProvider.init(std.testing.allocator, .{ .maximum_requests = 1, .poll_work_budget = 1 });
    defer {
        runtime.deinit();
        binding.deinit();
    }
    var listener = try transport.TcpListener.init(transport.Ipv4Address.wildcard(0), 1);
    defer listener.shutdown();
    const endpoint = try transport.Ipv4Address.parse("127.0.0.1", (try listener.local_address()).port);
    try runtime.registerProvider(try binding.asProvider());
    try runtime.start();
    var username = [_]u8{ 'u', 's', 'e', 'r' };
    const credentials = protocol.StunShortTermCredentials{ .username = username[0..], .password = "password" };
    const request = try binding.startBinding(.{ .server = endpoint, .timeout_ns = std.time.ns_per_s, .credentials = credentials });
    username[0] = 'x';
    var server_connection: ?transport.TcpConnection = null;
    defer if (server_connection) |*connection| connection.close();
    var inbound: [max_tcp_stun_binding_frame_bytes]u8 = undefined;
    var reader = try StunFrameReader.init(inbound[0..]);
    var writer = StunFrameWriter{};
    var responses: usize = 0;
    var refreshed = false;
    var completed = false;
    var attempt: usize = 0;
    while (attempt < 300) : (attempt += 1) {
        var outcome = try runtime.poll(.{ .now_ns = @intCast(attempt), .work_budget = 1 });
        outcome.deinit();
        if (server_connection == null) {
            if (listener.accept()) |pending| {
                var owned_pending = pending;
                server_connection = (listener.admit(&owned_pending, .allow) orelse unreachable).connection;
            } else |err| switch (err) {
                error.WouldBlock => {},
                else => return err,
            }
        }
        if (server_connection) |*connection| {
            if (writer.payload) |_| {
                _ = try writer.flush(connection);
            } else if (try reader.read(connection)) |frame| {
                var attributes: [2]protocol.StunAttribute = undefined;
                const decoded = try protocol.decode_stun_message(frame, attributes[0..]);
                try std.testing.expectEqual(protocol.StunClass.request, decoded.header.class);
                try std.testing.expectEqual(@as(usize, 2), decoded.count);
                try std.testing.expectEqualStrings("user", attributes[0].value);
                try verifyFrameIntegrity(.{ .username = "user", .password = "password" }, frame);
                const mapped = protocol.StunAddress{ .ipv4 = .{ .octets = .{ 127, 0, 0, 1 }, .port = 40000 + @as(u16, @intCast(responses)) } };
                var response: [128]u8 = undefined;
                try writer.begin(try encodeBindingResponse(decoded.header.transaction_id, mapped, .{ .username = "user", .password = "password" }, response[0..]));
                _ = try writer.flush(connection);
                responses += 1;
            }
        }
        if (!refreshed) {
            if (binding.result(request)) |mapped| {
                try std.testing.expectEqual(protocol.StunAddress{ .ipv4 = .{ .octets = .{ 127, 0, 0, 1 }, .port = 40000 } }, mapped);
                try binding.refreshBinding(request);
                refreshed = true;
            } else |err| switch (err) {
                error.NotReady => {},
                else => return err,
            }
        } else if (binding.result(request)) |mapped| {
            try std.testing.expectEqual(protocol.StunAddress{ .ipv4 = .{ .octets = .{ 127, 0, 0, 1 }, .port = 40001 } }, mapped);
            completed = true;
            break;
        } else |err| switch (err) {
            error.NotReady => {},
            else => return err,
        }
        std.Thread.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(completed);
    try std.testing.expectEqual(@as(usize, 2), responses);
    try binding.release(request);
    var closed = false;
    attempt = 0;
    while (attempt < 100) : (attempt += 1) {
        if (server_connection) |*connection| {
            _ = reader.read(connection) catch |err| {
                if (err == error.ConnectionClosed) {
                    closed = true;
                    break;
                }
                return err;
            };
        }
        std.Thread.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(closed);
}

test "runtime TCP STUN providers bound requests and cancel pending connections" {
    var provider_value = try TcpStunBindingProvider.init(std.testing.allocator, .{ .maximum_requests = 1 });
    defer provider_value.deinit();
    const config_value = TcpStunBindingRequestConfig{ .server = try transport.Ipv4Address.parse("127.0.0.1", 3478), .timeout_ns = std.time.ns_per_ms };
    try std.testing.expectError(error.Inactive, provider_value.startBinding(config_value));
    provider_value.active = true;
    const request = try provider_value.startBinding(config_value);
    try std.testing.expectError(error.RequestCapacityExceeded, provider_value.startBinding(config_value));
    try std.testing.expectError(error.NotReady, provider_value.refreshBinding(request));
    try provider_value.cancel(request);
    try std.testing.expectEqual(TcpStunBindingRequestState.cancelled, try provider_value.state(request));
    try provider_value.release(request);
    try std.testing.expectError(error.StaleRequest, provider_value.state(request));
}
