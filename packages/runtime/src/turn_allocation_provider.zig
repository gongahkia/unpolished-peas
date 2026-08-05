const std = @import("std");
const core = @import("minna-san-core");
const protocol = @import("minna-san-protocol");
const topology = @import("minna-san-topology");
const transport = @import("minna-san-transport");
const provider = @import("provider.zig");

pub const max_turn_allocations: usize = core.max_session_capacity;
pub const max_turn_allocation_response_bytes: usize = 4096;
pub const max_turn_allocation_request_bytes: usize = protocol.stun_header_bytes + 8 + 3 * (4 + std.mem.alignForward(usize, protocol.max_stun_credential_bytes, 4)) + 4 + protocol.stun_integrity_tag_bytes;

pub const TurnAllocationProviderError = std.mem.Allocator.Error || provider.ProviderError || transport.UdpSocketError || transport.UdpDatagramError || topology.TurnAllocationError || protocol.StunCodecError || protocol.StunCredentialError || error{ InvalidConfiguration, Inactive, AllocationCapacityExceeded, StaleAllocation, NotReady, Cancelled, AllocationFailed, AllocationExpired };

pub const TurnAllocationProviderConfig = struct {
    maximum_allocations: usize = 64,
    poll_work_budget: usize = 1,

    pub fn validate(self: TurnAllocationProviderConfig) TurnAllocationProviderError!void {
        if (self.maximum_allocations == 0 or self.maximum_allocations > max_turn_allocations or self.poll_work_budget == 0 or self.poll_work_budget > core.max_poll_work_budget) return error.InvalidConfiguration;
    }
};

pub const TurnAllocationRequestConfig = struct {
    server: transport.Ipv4Address,
    local_address: transport.Ipv4Address = transport.Ipv4Address.wildcard(0),
    credentials: protocol.StunLongTermCredentials,
    requested_lifetime_seconds: u32,
    response_timeout_ns: core.TimeNs,

    pub fn validate(self: TurnAllocationRequestConfig) TurnAllocationProviderError!void {
        if (self.server.port == 0 or self.requested_lifetime_seconds == 0 or self.response_timeout_ns == 0) return error.InvalidConfiguration;
        try protocol.validate_long_term_credentials(self.credentials);
    }
};

pub const TurnAllocationHandle = struct {
    provider_id: u32,
    slot: u32,
    generation: u32,
};

pub const TurnAllocationState = enum { pending, allocated, expired, failed, cancelled };

const OwnedCredentials = struct {
    username: [protocol.max_stun_credential_bytes]u8 = [_]u8{0} ** protocol.max_stun_credential_bytes,
    username_len: usize = 0,
    password: [protocol.max_stun_credential_bytes]u8 = [_]u8{0} ** protocol.max_stun_credential_bytes,
    password_len: usize = 0,
    realm: [protocol.max_stun_credential_bytes]u8 = [_]u8{0} ** protocol.max_stun_credential_bytes,
    realm_len: usize = 0,
    nonce: [protocol.max_stun_credential_bytes]u8 = [_]u8{0} ** protocol.max_stun_credential_bytes,
    nonce_len: usize = 0,

    fn init(input: protocol.StunLongTermCredentials) protocol.StunCredentialError!OwnedCredentials {
        try protocol.validate_long_term_credentials(input);
        var result = OwnedCredentials{ .username_len = input.username.len, .password_len = input.password.len, .realm_len = input.realm.len, .nonce_len = input.nonce.len };
        @memcpy(result.username[0..result.username_len], input.username);
        @memcpy(result.password[0..result.password_len], input.password);
        @memcpy(result.realm[0..result.realm_len], input.realm);
        @memcpy(result.nonce[0..result.nonce_len], input.nonce);
        return result;
    }

    fn value(self: *const OwnedCredentials) protocol.StunLongTermCredentials {
        return .{ .username = self.username[0..self.username_len], .password = self.password[0..self.password_len], .realm = self.realm[0..self.realm_len], .nonce = self.nonce[0..self.nonce_len], .algorithm = .sha256 };
    }

    fn deinit(self: *OwnedCredentials) void {
        std.crypto.secureZero(u8, &self.username);
        std.crypto.secureZero(u8, &self.password);
        std.crypto.secureZero(u8, &self.realm);
        std.crypto.secureZero(u8, &self.nonce);
        self.username_len = 0;
        self.password_len = 0;
        self.realm_len = 0;
        self.nonce_len = 0;
    }
};

const Request = struct {
    socket: transport.UdpSocket,
    socket_open: bool = true,
    client: topology.TurnAllocationClient,
    credentials: OwnedCredentials,
    response_timeout_ns: core.TimeNs,
    request_deadline_ns: ?core.TimeNs = null,
    outbound: [max_turn_allocation_request_bytes]u8 = undefined,
    outbound_len: usize = 0,
    state: TurnAllocationState = .pending,
    allocation: ?topology.TurnAllocation = null,

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

pub const TurnAllocationProvider = struct {
    allocator: std.mem.Allocator,
    config: TurnAllocationProviderConfig,
    provider_id: u32,
    slots: []Slot,
    next_slot: usize = 0,
    active: bool = false,

    pub fn init(allocator: std.mem.Allocator, config: TurnAllocationProviderConfig) TurnAllocationProviderError!TurnAllocationProvider {
        try config.validate();
        const provider_id = next_provider_id.fetchAdd(1, .monotonic);
        if (provider_id == 0) return error.InvalidConfiguration;
        const slots = try allocator.alloc(Slot, config.maximum_allocations);
        for (slots) |*slot| slot.* = .{};
        return .{ .allocator = allocator, .config = config, .provider_id = provider_id, .slots = slots };
    }

    pub fn deinit(self: *TurnAllocationProvider) void {
        for (self.slots, 0..) |slot, index| if (slot.request != null) self.destroyRequest(index);
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    pub fn asProvider(self: *TurnAllocationProvider) provider.ProviderError!provider.Provider {
        return provider.Provider.init(.{ .name = "turn-allocation", .poll_work_budget = self.config.poll_work_budget }, self, .{ .init = providerInit, .query_capabilities = queryCapabilities, .poll = providerPoll, .teardown = providerTeardown });
    }

    pub fn startAllocation(self: *TurnAllocationProvider, config_value: TurnAllocationRequestConfig) TurnAllocationProviderError!TurnAllocationHandle {
        if (!self.active) return error.Inactive;
        try config_value.validate();
        const index = self.freeSlot() orelse return error.AllocationCapacityExceeded;
        var socket = try transport.UdpSocket.init(.{});
        var socket_owned = true;
        errdefer if (socket_owned) socket.close();
        try socket.bind(config_value.local_address);
        var credentials = try OwnedCredentials.init(config_value.credentials);
        var credentials_owned = true;
        errdefer if (credentials_owned) credentials.deinit();
        const request = try self.allocator.create(Request);
        var request_owned = true;
        errdefer if (request_owned) self.allocator.destroy(request);
        request.* = .{ .socket = socket, .client = undefined, .credentials = credentials, .response_timeout_ns = config_value.response_timeout_ns };
        socket_owned = false;
        credentials_owned = false;
        errdefer if (request_owned) request.deinit();
        var transaction_id: [12]u8 = undefined;
        std.crypto.random.bytes(&transaction_id);
        request.client = try topology.TurnAllocationClient.init(.{ .server = config_value.server, .credentials = request.credentials.value(), .requested_lifetime_seconds = config_value.requested_lifetime_seconds }, transaction_id);
        self.slots[index].request = request;
        request_owned = false;
        return .{ .provider_id = self.provider_id, .slot = @intCast(index), .generation = self.slots[index].generation };
    }

    pub fn state(self: *TurnAllocationProvider, handle: TurnAllocationHandle) TurnAllocationProviderError!TurnAllocationState {
        return (try self.lookupRequest(handle)).state;
    }

    pub fn allocation(self: *TurnAllocationProvider, handle: TurnAllocationHandle) TurnAllocationProviderError!topology.TurnAllocation {
        const request = try self.lookupRequest(handle);
        return switch (request.state) {
            .pending => error.NotReady,
            .allocated => request.allocation orelse error.AllocationFailed,
            .expired => error.AllocationExpired,
            .failed => error.AllocationFailed,
            .cancelled => error.Cancelled,
        };
    }

    pub fn cancel(self: *TurnAllocationProvider, handle: TurnAllocationHandle) TurnAllocationProviderError!void {
        const request = try self.lookupRequest(handle);
        if (request.state != .pending) return error.NotReady;
        request.closeSocket();
        request.state = .cancelled;
    }

    pub fn release(self: *TurnAllocationProvider, handle: TurnAllocationHandle) TurnAllocationProviderError!void {
        const request = try self.lookupRequest(handle);
        if (request.state == .pending) return error.NotReady;
        self.destroyRequest(handle.slot);
    }

    fn poll(self: *TurnAllocationProvider, now_ns: core.TimeNs, work_budget: usize) provider.ProviderPollResult {
        var poll_result = provider.ProviderPollResult{};
        var inspected: usize = 0;
        while (inspected < work_budget) : (inspected += 1) {
            const index = self.next_slot;
            self.next_slot = (self.next_slot + 1) % self.slots.len;
            const request = self.slots[index].request orelse continue;
            if (request.state == .pending) {
                if (self.pollPending(request, now_ns)) poll_result.work_completed += 1;
            } else if (request.state == .allocated) {
                const allocation_value = request.allocation orelse {
                    request.state = .failed;
                    continue;
                };
                if (now_ns >= allocation_value.expires_at_ns) {
                    request.closeSocket();
                    request.state = .expired;
                    poll_result.work_completed += 1;
                }
            }
            switch (request.state) {
                .pending => if (request.request_deadline_ns) |deadline| {
                    poll_result.next_deadline = earliest(poll_result.next_deadline, deadline);
                },
                .allocated => if (request.allocation) |allocation_value| {
                    poll_result.next_deadline = earliest(poll_result.next_deadline, allocation_value.expires_at_ns);
                },
                else => {},
            }
        }
        return poll_result;
    }

    fn pollPending(self: *TurnAllocationProvider, request: *Request, now_ns: core.TimeNs) bool {
        if (request.request_deadline_ns) |deadline| if (now_ns >= deadline) {
            self.failRequest(request);
            return true;
        };
        if (request.client.started_at_ns == null) {
            const encoded = request.client.begin(now_ns, request.outbound[0..]) catch {
                self.failRequest(request);
                return true;
            };
            request.outbound_len = encoded.len;
            request.request_deadline_ns = now_ns +| request.response_timeout_ns;
        }
        if (request.outbound_len != 0) {
            _ = request.socket.send_to(request.outbound[0..request.outbound_len], request.client.config.server) catch |err| switch (err) {
                error.WouldBlock => return false,
                else => {
                    self.failRequest(request);
                    return true;
                },
            };
            request.outbound_len = 0;
            return true;
        }
        var storage: [transport.max_ipv4_datagram_bytes]u8 = undefined;
        const datagram = request.socket.receive_from(storage[0..]) catch |err| switch (err) {
            error.WouldBlock => return false,
            else => {
                self.failRequest(request);
                return true;
            },
        };
        if (!sameAddress(datagram.source, request.client.config.server)) return true;
        if (datagram.bytes.len > max_turn_allocation_response_bytes) {
            self.failRequest(request);
            return true;
        }
        var attributes: [16]protocol.StunAttribute = undefined;
        const allocation_value = request.client.receive_frame(now_ns, datagram.bytes, attributes[0..]) catch {
            self.failRequest(request);
            return true;
        };
        request.allocation = allocation_value;
        request.state = .allocated;
        request.request_deadline_ns = null;
        return true;
    }

    fn failRequest(_: *TurnAllocationProvider, request: *Request) void {
        request.closeSocket();
        request.state = .failed;
        request.request_deadline_ns = null;
    }

    fn lookupRequest(self: *TurnAllocationProvider, handle: TurnAllocationHandle) TurnAllocationProviderError!*Request {
        if (handle.provider_id != self.provider_id or handle.slot >= self.slots.len) return error.StaleAllocation;
        const slot = &self.slots[handle.slot];
        if (slot.generation != handle.generation) return error.StaleAllocation;
        return slot.request orelse error.StaleAllocation;
    }

    fn freeSlot(self: *const TurnAllocationProvider) ?usize {
        for (self.slots, 0..) |slot, index| if (slot.request == null) return index;
        return null;
    }

    fn destroyRequest(self: *TurnAllocationProvider, index: usize) void {
        const slot = &self.slots[index];
        const request = slot.request orelse return;
        request.deinit();
        self.allocator.destroy(request);
        slot.request = null;
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
    }

    fn providerInit(context: ?*anyopaque) callconv(.c) c_int {
        const self: *TurnAllocationProvider = @ptrCast(@alignCast(context orelse return @intFromEnum(core.CResult.invalid_argument)));
        if (self.active) return @intFromEnum(core.CResult.invalid_state);
        self.active = true;
        return @intFromEnum(core.CResult.ok);
    }

    fn queryCapabilities(context: ?*anyopaque, out_capabilities: *provider.ProviderCapabilityDescriptor) callconv(.c) c_int {
        _ = context;
        out_capabilities.* = .{ .transport_bits = core.transport_capability_bit(.udp), .protocol_bits = core.protocol_capability_bit(.turn) };
        return @intFromEnum(core.CResult.ok);
    }

    fn providerPoll(context: ?*anyopaque, now_ns: core.TimeNs, work_budget: usize, out_result: *provider.ProviderPollOutput) callconv(.c) c_int {
        const self: *TurnAllocationProvider = @ptrCast(@alignCast(context orelse return @intFromEnum(core.CResult.invalid_argument)));
        if (!self.active) return @intFromEnum(core.CResult.invalid_state);
        const poll_result = self.poll(now_ns, work_budget);
        out_result.* = .{ .work_completed = poll_result.work_completed, .next_deadline_ns = poll_result.next_deadline orelse 0, .has_next_deadline = if (poll_result.next_deadline != null) 1 else 0 };
        return @intFromEnum(core.CResult.ok);
    }

    fn providerTeardown(context: ?*anyopaque) callconv(.c) void {
        const self: *TurnAllocationProvider = @ptrCast(@alignCast(context orelse return));
        self.active = false;
        for (self.slots) |slot| {
            const request = slot.request orelse continue;
            request.closeSocket();
            if (request.state == .pending) request.state = .cancelled;
        }
    }
};

fn earliest(current: ?core.TimeNs, candidate: core.TimeNs) core.TimeNs {
    return if (current) |value| @min(value, candidate) else candidate;
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

fn verifyFrameIntegrity(credentials: protocol.StunLongTermCredentials, frame: []const u8) !void {
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
            var key = try longTermKey(credentials);
            defer std.crypto.secureZero(u8, &key);
            var context = std.crypto.auth.hmac.sha2.HmacSha256.init(&key);
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

fn longTermKey(credentials: protocol.StunLongTermCredentials) protocol.StunCredentialError![32]u8 {
    try protocol.validate_long_term_credentials(credentials);
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    digest.update(credentials.username);
    digest.update(":");
    digest.update(credentials.realm);
    digest.update(":");
    digest.update(credentials.password);
    var key: [32]u8 = undefined;
    digest.final(&key);
    return key;
}

fn encodeAllocationResponse(transaction_id: [12]u8, relay: protocol.StunAddress, lifetime_seconds: u32, credentials: protocol.StunLongTermCredentials, output: []u8) ![]u8 {
    var address: [20]u8 = undefined;
    var lifetime: [4]u8 = undefined;
    const relay_value = try protocol.encode_xor_address(relay, transaction_id, address[0..]);
    std.mem.writeInt(u32, lifetime[0..], lifetime_seconds, .big);
    var integrity = [_]u8{0} ** protocol.stun_integrity_tag_bytes;
    const attributes = [_]protocol.StunAttribute{ .{ .kind = 0x0016, .value = relay_value }, .{ .kind = 0x000d, .value = lifetime[0..] }, .{ .kind = 0x001c, .value = integrity[0..] } };
    const encoded = try protocol.encode_stun_message(.{ .method = 3, .class = .success_response, .transaction_id = transaction_id }, attributes[0..], output);
    var value_offset: ?usize = null;
    var offset: usize = protocol.stun_header_bytes;
    while (offset < encoded.len) {
        const kind = std.mem.readInt(u16, encoded[offset..][0..2], .big);
        const value_len: usize = std.mem.readInt(u16, encoded[offset + 2 ..][0..2], .big);
        if (kind == 0x001c) {
            value_offset = offset + 4;
            break;
        }
        offset += 4 + std.mem.alignForward(usize, value_len, 4);
    }
    const integrity_offset = value_offset orelse return error.InvalidConfiguration;
    const expected = try protocol.stun_long_term_integrity(credentials, encoded[0..integrity_offset]);
    @memcpy(encoded[integrity_offset..][0..protocol.stun_integrity_tag_bytes], &expected);
    return encoded;
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

test "runtime TURN allocation providers expose authenticated relay allocations and expiry" {
    var manual = core.ManualClock.init(0);
    const sdk = try @import("sdk_config.zig").SdkConfigBuilder.init().with_clock(manual.clock()).with_platform_config(.{ .limits = .{ .provider_capacity = 1, .poll_work_budget = 1 } }).build();
    var runtime = try @import("platform_runtime.zig").Runtime.init(std.testing.allocator, sdk);
    var allocations = try TurnAllocationProvider.init(std.testing.allocator, .{ .maximum_allocations = 1, .poll_work_budget = 1 });
    defer {
        runtime.deinit();
        allocations.deinit();
    }
    var server = try transport.UdpSocket.init(.{});
    defer server.close();
    try server.bind(transport.Ipv4Address.wildcard(0));
    const endpoint = try transport.Ipv4Address.parse("127.0.0.1", (try localAddress(&server)).port);
    try runtime.registerProvider(try allocations.asProvider());
    try runtime.start();
    var username = [_]u8{ 'u', 's', 'e', 'r' };
    const credentials = protocol.StunLongTermCredentials{ .username = username[0..], .password = "password", .realm = "realm", .nonce = "nonce", .algorithm = .sha256 };
    const request = try allocations.startAllocation(.{ .server = endpoint, .credentials = credentials, .requested_lifetime_seconds = 2, .response_timeout_ns = std.time.ns_per_s });
    username[0] = 'x';
    var first = try runtime.poll(.{ .now_ns = 0, .work_budget = 1 });
    first.deinit();
    var storage: [transport.max_ipv4_datagram_bytes]u8 = undefined;
    const received = try receiveWithRetry(&server, storage[0..]);
    var attributes: [5]protocol.StunAttribute = undefined;
    const decoded = try protocol.decode_stun_message(received.bytes, attributes[0..]);
    try std.testing.expectEqual(protocol.StunClass.request, decoded.header.class);
    try std.testing.expectEqual(@as(usize, 5), decoded.count);
    try std.testing.expectEqualStrings("user", attributes[1].value);
    try verifyFrameIntegrity(.{ .username = "user", .password = "password", .realm = "realm", .nonce = "nonce", .algorithm = .sha256 }, received.bytes);
    const relay = protocol.StunAddress{ .ipv4 = .{ .octets = .{ 203, 0, 113, 1 }, .port = 5000 } };
    var response: [128]u8 = undefined;
    _ = try server.send_to(try encodeAllocationResponse(decoded.header.transaction_id, relay, 2, .{ .username = "user", .password = "password", .realm = "realm", .nonce = "nonce", .algorithm = .sha256 }, response[0..]), received.source);
    var allocated = false;
    var attempt: usize = 0;
    while (attempt < 100) : (attempt += 1) {
        var outcome = try runtime.poll(.{ .now_ns = 1, .work_budget = 1 });
        outcome.deinit();
        if (allocations.allocation(request)) |value| {
            try std.testing.expectEqual(relay, value.relay);
            try std.testing.expectEqual(@as(core.TimeNs, 2 * std.time.ns_per_s), value.expires_at_ns);
            allocated = true;
            break;
        } else |err| switch (err) {
            error.NotReady => std.Thread.sleep(std.time.ns_per_ms),
            else => return err,
        }
    }
    try std.testing.expect(allocated);
    var expiry = try runtime.poll(.{ .now_ns = 2 * std.time.ns_per_s, .work_budget = 1 });
    expiry.deinit();
    try std.testing.expectEqual(TurnAllocationState.expired, try allocations.state(request));
    try std.testing.expectError(error.AllocationExpired, allocations.allocation(request));
    try allocations.release(request);
}

test "runtime TURN allocation providers bound pending allocations and cancellation" {
    var allocations = try TurnAllocationProvider.init(std.testing.allocator, .{ .maximum_allocations = 1 });
    defer allocations.deinit();
    const credentials = protocol.StunLongTermCredentials{ .username = "u", .password = "p", .realm = "r", .nonce = "n", .algorithm = .sha256 };
    const config_value = TurnAllocationRequestConfig{ .server = try transport.Ipv4Address.parse("127.0.0.1", 3478), .credentials = credentials, .requested_lifetime_seconds = 1, .response_timeout_ns = 1 };
    try std.testing.expectError(error.Inactive, allocations.startAllocation(config_value));
    allocations.active = true;
    const request = try allocations.startAllocation(config_value);
    try std.testing.expectError(error.AllocationCapacityExceeded, allocations.startAllocation(config_value));
    try allocations.cancel(request);
    try std.testing.expectEqual(TurnAllocationState.cancelled, try allocations.state(request));
    try allocations.release(request);
    try std.testing.expectError(error.StaleAllocation, allocations.state(request));
    const timed_out = try allocations.startAllocation(config_value);
    _ = allocations.poll(0, 1);
    _ = allocations.poll(1, 1);
    try std.testing.expectEqual(TurnAllocationState.failed, try allocations.state(timed_out));
    try std.testing.expectError(error.AllocationFailed, allocations.allocation(timed_out));
    try allocations.release(timed_out);
}
