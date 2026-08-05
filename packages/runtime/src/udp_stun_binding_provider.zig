const std = @import("std");
const core = @import("minna-san-core");
const protocol = @import("minna-san-protocol");
const topology = @import("minna-san-topology");
const transport = @import("minna-san-transport");
const provider = @import("provider.zig");

pub const max_udp_stun_binding_requests: usize = core.max_session_capacity;
pub const max_udp_stun_binding_request_bytes: usize = protocol.stun_header_bytes + 4 + protocol.max_stun_credential_bytes + 3 + 4 + protocol.stun_integrity_tag_bytes;

pub const UdpStunBindingProviderError = std.mem.Allocator.Error || provider.ProviderError || transport.UdpSocketError || transport.UdpDatagramError || topology.UdpStunBindingError || protocol.StunCodecError || protocol.StunCredentialError || error{ InvalidConfiguration, Inactive, RequestCapacityExceeded, StaleRequest, NotReady, Cancelled, BindingFailed };

pub const UdpStunBindingProviderConfig = struct {
    maximum_requests: usize = 64,
    poll_work_budget: usize = 1,

    pub fn validate(self: UdpStunBindingProviderConfig) UdpStunBindingProviderError!void {
        if (self.maximum_requests == 0 or self.maximum_requests > max_udp_stun_binding_requests or self.poll_work_budget == 0 or self.poll_work_budget > core.max_poll_work_budget) return error.InvalidConfiguration;
    }
};

pub const UdpStunBindingRequestConfig = struct {
    server: transport.Ipv4Address,
    local_address: transport.Ipv4Address = transport.Ipv4Address.wildcard(0),
    initial_rto_ns: core.TimeNs,
    maximum_retransmissions: usize,
    maximum_alternate_servers: usize = 1,
    credentials: ?protocol.StunShortTermCredentials = null,

    pub fn validate(self: UdpStunBindingRequestConfig) UdpStunBindingProviderError!void {
        if (self.server.port == 0 or self.initial_rto_ns == 0 or self.maximum_retransmissions == 0) return error.InvalidConfiguration;
        if (self.credentials) |credentials| try protocol.validate_short_term_credentials(credentials);
    }
};

pub const UdpStunBindingRequestHandle = struct {
    provider_id: u32,
    slot: u32,
    generation: u32,
};

pub const UdpStunBindingRequestState = enum { pending, mapped, failed, cancelled };

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

const Request = struct {
    socket: transport.UdpSocket,
    socket_open: bool = true,
    client: topology.UdpStunBindingClient,
    credentials: OwnedCredentials,
    pending_send: ?topology.UdpStunBindingSend = null,
    state: UdpStunBindingRequestState = .pending,
    result: ?protocol.StunAddress = null,

    fn closeSocket(self: *Request) void {
        if (!self.socket_open) return;
        self.socket.close();
        self.socket_open = false;
    }

    fn deinit(self: *Request) void {
        self.closeSocket();
        self.credentials.deinit();
        self.* = undefined;
    }
};

const Slot = struct {
    generation: u32 = 1,
    request: ?*Request = null,
};

var next_provider_id = std.atomic.Value(u32).init(1);

pub const UdpStunBindingProvider = struct {
    allocator: std.mem.Allocator,
    config: UdpStunBindingProviderConfig,
    provider_id: u32,
    slots: []Slot,
    next_slot: usize = 0,
    active: bool = false,

    pub fn init(allocator: std.mem.Allocator, config: UdpStunBindingProviderConfig) UdpStunBindingProviderError!UdpStunBindingProvider {
        try config.validate();
        const provider_id = next_provider_id.fetchAdd(1, .monotonic);
        if (provider_id == 0) return error.InvalidConfiguration;
        const slots = try allocator.alloc(Slot, config.maximum_requests);
        for (slots) |*slot| slot.* = .{};
        return .{ .allocator = allocator, .config = config, .provider_id = provider_id, .slots = slots };
    }

    pub fn deinit(self: *UdpStunBindingProvider) void {
        for (self.slots, 0..) |slot, index| if (slot.request != null) self.destroyRequest(index);
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    pub fn asProvider(self: *UdpStunBindingProvider) provider.ProviderError!provider.Provider {
        return provider.Provider.init(.{ .name = "udp-stun", .poll_work_budget = self.config.poll_work_budget }, self, .{ .init = providerInit, .query_capabilities = queryCapabilities, .poll = providerPoll, .teardown = providerTeardown });
    }

    pub fn startBinding(self: *UdpStunBindingProvider, config_value: UdpStunBindingRequestConfig) UdpStunBindingProviderError!UdpStunBindingRequestHandle {
        if (!self.active) return error.Inactive;
        try config_value.validate();
        const index = self.freeSlot() orelse return error.RequestCapacityExceeded;
        var socket = try transport.UdpSocket.init(.{});
        errdefer socket.close();
        try socket.bind(config_value.local_address);
        var transaction_id: [12]u8 = undefined;
        std.crypto.random.bytes(&transaction_id);
        const client = try topology.UdpStunBindingClient.init(.{
            .server = config_value.server,
            .initial_rto_ns = config_value.initial_rto_ns,
            .maximum_retransmissions = config_value.maximum_retransmissions,
            .maximum_alternate_servers = config_value.maximum_alternate_servers,
        }, transaction_id);
        var credentials = try OwnedCredentials.init(config_value.credentials);
        errdefer credentials.deinit();
        const request = try self.allocator.create(Request);
        errdefer self.allocator.destroy(request);
        request.* = .{ .socket = socket, .client = client, .credentials = credentials };
        self.slots[index].request = request;
        return .{ .provider_id = self.provider_id, .slot = @intCast(index), .generation = self.slots[index].generation };
    }

    pub fn state(self: *UdpStunBindingProvider, handle: UdpStunBindingRequestHandle) UdpStunBindingProviderError!UdpStunBindingRequestState {
        return (try self.lookupRequest(handle)).state;
    }

    pub fn result(self: *UdpStunBindingProvider, handle: UdpStunBindingRequestHandle) UdpStunBindingProviderError!protocol.StunAddress {
        const request = try self.lookupRequest(handle);
        return switch (request.state) {
            .pending => error.NotReady,
            .mapped => request.result orelse error.BindingFailed,
            .failed => error.BindingFailed,
            .cancelled => error.Cancelled,
        };
    }

    pub fn cancel(self: *UdpStunBindingProvider, handle: UdpStunBindingRequestHandle) UdpStunBindingProviderError!void {
        const request = try self.lookupRequest(handle);
        if (request.state != .pending) return error.NotReady;
        request.closeSocket();
        request.state = .cancelled;
    }

    pub fn release(self: *UdpStunBindingProvider, handle: UdpStunBindingRequestHandle) UdpStunBindingProviderError!void {
        const request = try self.lookupRequest(handle);
        if (request.state == .pending) return error.NotReady;
        self.destroyRequest(handle.slot);
    }

    fn poll(self: *UdpStunBindingProvider, now_ns: core.TimeNs, work_budget: usize) provider.ProviderPollResult {
        var poll_result = provider.ProviderPollResult{};
        var inspected: usize = 0;
        while (inspected < work_budget) : (inspected += 1) {
            const index = self.next_slot;
            self.next_slot = (self.next_slot + 1) % self.slots.len;
            const request = self.slots[index].request orelse continue;
            if (request.state != .pending) continue;
            if (self.pollRequest(request, now_ns)) poll_result.work_completed += 1;
            if (request.state != .pending) continue;
            if (request.pending_send == null) if (request.client.next_retry_ns) |deadline| {
                poll_result.next_deadline = if (poll_result.next_deadline) |current| @min(current, deadline) else deadline;
            };
        }
        return poll_result;
    }

    fn pollRequest(self: *UdpStunBindingProvider, request: *Request, now_ns: core.TimeNs) bool {
        if (request.pending_send == null) {
            if (request.client.next_retry_ns == null) {
                request.pending_send = request.client.begin(now_ns) catch {
                    self.failRequest(request);
                    return true;
                };
            } else {
                request.pending_send = request.client.poll(now_ns) catch {
                    self.failRequest(request);
                    return true;
                };
            }
        }
        var completed = false;
        if (request.pending_send) |send| {
            self.sendRequest(request, send) catch |err| switch (err) {
                error.WouldBlock => return completed,
                else => {
                    self.failRequest(request);
                    return true;
                },
            };
            if (request.state == .pending) {
                request.pending_send = null;
                completed = true;
            }
        }
        var storage: [transport.max_ipv4_datagram_bytes]u8 = undefined;
        const datagram = request.socket.receive_from(storage[0..]) catch |err| switch (err) {
            error.WouldBlock => return completed,
            else => {
                self.failRequest(request);
                return true;
            },
        };
        if (!sameAddress(datagram.source, request.client.server)) return true;
        var attributes: [16]protocol.StunAttribute = undefined;
        const decoded = protocol.decode_stun_message(datagram.bytes, attributes[0..]) catch return true;
        if (decoded.header.class == .success_response) if (request.credentials.value()) |credentials| verifyResponseIntegrity(credentials, datagram.bytes) catch return true;
        const binding = request.client.receive(decoded.header, attributes[0..decoded.count]) catch |err| switch (err) {
            error.UnexpectedResponse => return true,
            else => {
                self.failRequest(request);
                return true;
            },
        };
        switch (binding) {
            .mapped => |mapped| {
                request.result = mapped;
                request.closeSocket();
                request.state = .mapped;
            },
            .alternate => {
                request.pending_send = request.client.begin(now_ns) catch {
                    self.failRequest(request);
                    return true;
                };
            },
        }
        return true;
    }

    fn sendRequest(_: *UdpStunBindingProvider, request: *Request, send: topology.UdpStunBindingSend) UdpStunBindingProviderError!void {
        var frame: [max_udp_stun_binding_request_bytes]u8 = undefined;
        const encoded = try encodeBindingRequest(send.transaction_id, request.credentials.value(), frame[0..]);
        _ = try request.socket.send_to(encoded, send.server);
    }

    fn failRequest(_: *UdpStunBindingProvider, request: *Request) void {
        request.closeSocket();
        request.state = .failed;
        request.pending_send = null;
    }

    fn lookupRequest(self: *UdpStunBindingProvider, handle: UdpStunBindingRequestHandle) UdpStunBindingProviderError!*Request {
        if (handle.provider_id != self.provider_id or handle.slot >= self.slots.len) return error.StaleRequest;
        const slot = &self.slots[handle.slot];
        if (slot.generation != handle.generation) return error.StaleRequest;
        return slot.request orelse error.StaleRequest;
    }

    fn freeSlot(self: *const UdpStunBindingProvider) ?usize {
        for (self.slots, 0..) |slot, index| if (slot.request == null) return index;
        return null;
    }

    fn destroyRequest(self: *UdpStunBindingProvider, index: usize) void {
        const slot = &self.slots[index];
        const request = slot.request orelse return;
        request.deinit();
        self.allocator.destroy(request);
        slot.request = null;
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
    }

    fn providerInit(context: ?*anyopaque) callconv(.c) c_int {
        const self: *UdpStunBindingProvider = @ptrCast(@alignCast(context orelse return @intFromEnum(core.CResult.invalid_argument)));
        if (self.active) return @intFromEnum(core.CResult.invalid_state);
        self.active = true;
        return @intFromEnum(core.CResult.ok);
    }

    fn queryCapabilities(context: ?*anyopaque, out_capabilities: *provider.ProviderCapabilityDescriptor) callconv(.c) c_int {
        _ = context;
        out_capabilities.* = .{ .transport_bits = core.transport_capability_bit(.udp), .protocol_bits = core.protocol_capability_bit(.stun) };
        return @intFromEnum(core.CResult.ok);
    }

    fn providerPoll(context: ?*anyopaque, now_ns: core.TimeNs, work_budget: usize, out_result: *provider.ProviderPollOutput) callconv(.c) c_int {
        const self: *UdpStunBindingProvider = @ptrCast(@alignCast(context orelse return @intFromEnum(core.CResult.invalid_argument)));
        if (!self.active) return @intFromEnum(core.CResult.invalid_state);
        const poll_result = self.poll(now_ns, work_budget);
        out_result.* = .{ .work_completed = poll_result.work_completed, .next_deadline_ns = poll_result.next_deadline orelse 0, .has_next_deadline = if (poll_result.next_deadline != null) 1 else 0 };
        return @intFromEnum(core.CResult.ok);
    }

    fn providerTeardown(context: ?*anyopaque) callconv(.c) void {
        const self: *UdpStunBindingProvider = @ptrCast(@alignCast(context orelse return));
        self.active = false;
        for (self.slots) |slot| {
            const request = slot.request orelse continue;
            if (request.state != .pending) continue;
            request.closeSocket();
            request.state = .cancelled;
        }
    }
};

fn encodeBindingRequest(transaction_id: [12]u8, credentials: ?protocol.StunShortTermCredentials, output: []u8) UdpStunBindingProviderError![]u8 {
    const value = credentials orelse return protocol.encode_stun_message(.{ .method = 1, .class = .request, .transaction_id = transaction_id }, &.{}, output);
    var integrity = [_]u8{0} ** protocol.stun_integrity_tag_bytes;
    const attributes = [_]protocol.StunAttribute{ .{ .kind = 0x0006, .value = value.username }, .{ .kind = 0x001c, .value = integrity[0..] } };
    const encoded = try protocol.encode_stun_message(.{ .method = 1, .class = .request, .transaction_id = transaction_id }, attributes[0..], output);
    const integrity_offset = protocol.stun_header_bytes + 4 + std.mem.alignForward(usize, value.username.len, 4) + 4;
    const expected = try protocol.stun_short_term_integrity(value, encoded[0..integrity_offset]);
    @memcpy(encoded[integrity_offset..][0..protocol.stun_integrity_tag_bytes], &expected);
    return encoded;
}

fn verifyResponseIntegrity(credentials: protocol.StunShortTermCredentials, frame: []const u8) UdpStunBindingProviderError!void {
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

fn sameAddress(first: transport.Ipv4Address, second: transport.Ipv4Address) bool {
    return first.port == second.port and std.mem.eql(u8, &first.octets, &second.octets);
}

fn localAddress(socket: *transport.UdpSocket) !transport.Ipv4Address {
    var native = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
    var length = native.getOsSockLen();
    try std.posix.getsockname(socket.socket.handle, &native.any, &length);
    return transport.Ipv4Address.from_native(native);
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

test "runtime UDP STUN providers poll credentialed loopback binding responses" {
    var manual = core.ManualClock.init(0);
    const sdk = try @import("sdk_config.zig").SdkConfigBuilder.init().with_clock(manual.clock()).with_platform_config(.{ .limits = .{ .provider_capacity = 1, .poll_work_budget = 1 } }).build();
    var runtime = try @import("platform_runtime.zig").Runtime.init(std.testing.allocator, sdk);
    var binding = try UdpStunBindingProvider.init(std.testing.allocator, .{ .maximum_requests = 1, .poll_work_budget = 1 });
    defer {
        runtime.deinit();
        binding.deinit();
    }
    var server = try transport.UdpSocket.init(.{});
    defer server.close();
    try server.bind(transport.Ipv4Address.wildcard(0));
    const endpoint = try transport.Ipv4Address.parse("127.0.0.1", (try localAddress(&server)).port);
    try runtime.registerProvider(try binding.asProvider());
    try runtime.start();
    var username = [_]u8{ 'u', 's', 'e', 'r' };
    const credentials = protocol.StunShortTermCredentials{ .username = username[0..], .password = "password" };
    const request = try binding.startBinding(.{ .server = endpoint, .initial_rto_ns = 10, .maximum_retransmissions = 2, .credentials = credentials });
    username[0] = 'x';
    var first = try runtime.poll(.{ .now_ns = 0, .work_budget = 1 });
    first.deinit();
    var server_storage: [transport.max_ipv4_datagram_bytes]u8 = undefined;
    const received = try receiveWithRetry(&server, server_storage[0..]);
    var attributes: [2]protocol.StunAttribute = undefined;
    const decoded = try protocol.decode_stun_message(received.bytes, attributes[0..]);
    try std.testing.expectEqual(@as(usize, 2), decoded.count);
    try std.testing.expectEqualStrings("user", attributes[0].value);
    try verifyResponseIntegrity(credentials, received.bytes);
    const mapped = protocol.StunAddress{ .ipv4 = .{ .octets = received.source.octets, .port = received.source.port } };
    var response: [128]u8 = undefined;
    _ = try server.send_to(try encodeBindingResponse(decoded.header.transaction_id, mapped, credentials, response[0..]), received.source);
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        var outcome = try runtime.poll(.{ .now_ns = 1, .work_budget = 1 });
        outcome.deinit();
        if (binding.result(request)) |result| {
            try std.testing.expectEqual(mapped, result);
            break;
        } else |err| switch (err) {
            error.NotReady => std.Thread.sleep(std.time.ns_per_ms),
            else => return err,
        }
    }
    try std.testing.expect(attempts < 100);
    try binding.release(request);
}

test "runtime UDP STUN providers bound requests and cancel pending sockets" {
    var provider_value = try UdpStunBindingProvider.init(std.testing.allocator, .{ .maximum_requests = 1 });
    defer provider_value.deinit();
    const config_value = UdpStunBindingRequestConfig{ .server = try transport.Ipv4Address.parse("127.0.0.1", 3478), .initial_rto_ns = 1, .maximum_retransmissions = 1 };
    try std.testing.expectError(error.Inactive, provider_value.startBinding(config_value));
    provider_value.active = true;
    const request = try provider_value.startBinding(config_value);
    try std.testing.expectError(error.RequestCapacityExceeded, provider_value.startBinding(config_value));
    try provider_value.cancel(request);
    try std.testing.expectEqual(UdpStunBindingRequestState.cancelled, try provider_value.state(request));
    try provider_value.release(request);
    try std.testing.expectError(error.StaleRequest, provider_value.state(request));
}
