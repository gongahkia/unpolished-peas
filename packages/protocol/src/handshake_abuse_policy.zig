const std = @import("std");
const psk = @import("psk_authentication.zig");
const handshake = @import("secure_datagram_handshake.zig");

pub const max_secure_datagram_pending_sessions: usize = 65_536;
pub const max_secure_datagram_handshake_endpoints: usize = 65_536;

pub const SecureDatagramHandshakeEndpoint = u64;

pub const SecureDatagramHandshakeAbusePolicyError = error{InvalidConfiguration};

pub const SecureDatagramHandshakeAbusePolicy = struct {
    maximum_pending_sessions: usize = 256,
    maximum_endpoints: usize = 1_024,
    endpoint_burst: u32 = 8,
    endpoint_refill_interval_ns: u64 = std.time.ns_per_s,
    pending_session_timeout_ns: u64 = 5 * std.time.ns_per_s,
    endpoint_idle_timeout_ns: u64 = 60 * std.time.ns_per_s,

    pub fn validate(self: SecureDatagramHandshakeAbusePolicy) SecureDatagramHandshakeAbusePolicyError!void {
        if (self.maximum_pending_sessions == 0 or self.maximum_pending_sessions > max_secure_datagram_pending_sessions) return error.InvalidConfiguration;
        if (self.maximum_endpoints == 0 or self.maximum_endpoints > max_secure_datagram_handshake_endpoints) return error.InvalidConfiguration;
        if (self.endpoint_burst == 0 or self.endpoint_refill_interval_ns == 0 or self.pending_session_timeout_ns == 0 or self.endpoint_idle_timeout_ns == 0) return error.InvalidConfiguration;
    }
};

pub const SecureDatagramHandshakeServerError = std.mem.Allocator.Error || handshake.SecureDatagramHandshakeError || SecureDatagramHandshakeAbusePolicyError;

pub const SecureDatagramHandshakeServerResult = union(enum) {
    ignored,
    rate_limited,
    endpoint_capacity_reached,
    pending_capacity_reached,
    response: handshake.SecureDatagramHandshakeMessage,
    authenticated: struct {
        endpoint: SecureDatagramHandshakeEndpoint,
        response: handshake.SecureDatagramHandshakeMessage,
        handshake: handshake.SecureDatagramHandshake,
    },
};

pub const SecureDatagramHandshakeServer = struct {
    allocator: std.mem.Allocator,
    policy: SecureDatagramHandshakeAbusePolicy,
    key: psk.PskKey,
    pending: []PendingSession,
    pending_count: usize = 0,
    endpoints: []EndpointBucket,
    endpoint_count: usize = 0,

    const PendingSession = struct {
        endpoint: SecureDatagramHandshakeEndpoint,
        session_id: u64,
        handshake: handshake.SecureDatagramHandshake,
    };

    const EndpointBucket = struct {
        endpoint: SecureDatagramHandshakeEndpoint,
        tokens: u32,
        last_refill_ns: u64,
        last_seen_ns: u64,
    };

    pub fn init(allocator: std.mem.Allocator, policy: SecureDatagramHandshakeAbusePolicy, key_material: []const u8) SecureDatagramHandshakeServerError!SecureDatagramHandshakeServer {
        try policy.validate();
        var key = try psk.PskKey.init(key_material);
        errdefer key.clear();
        const pending = try allocator.alloc(PendingSession, policy.maximum_pending_sessions);
        errdefer allocator.free(pending);
        const endpoints = try allocator.alloc(EndpointBucket, policy.maximum_endpoints);
        errdefer allocator.free(endpoints);
        return .{ .allocator = allocator, .policy = policy, .key = key, .pending = pending, .endpoints = endpoints };
    }

    pub fn deinit(self: *SecureDatagramHandshakeServer) void {
        for (self.pending[0..self.pending_count]) |*entry| entry.handshake.deinit();
        self.allocator.free(self.pending);
        self.allocator.free(self.endpoints);
        self.key.clear();
        self.* = undefined;
    }

    pub fn pendingSessionCount(self: *const SecureDatagramHandshakeServer) usize {
        return self.pending_count;
    }

    pub fn endpointCount(self: *const SecureDatagramHandshakeServer) usize {
        return self.endpoint_count;
    }

    pub fn expire(self: *SecureDatagramHandshakeServer, now_ns: u64) usize {
        var expired: usize = 0;
        var index: usize = 0;
        while (index < self.pending_count) {
            if (self.pending[index].handshake.poll(now_ns)) {
                self.removePending(index);
                expired += 1;
                continue;
            }
            index += 1;
        }
        self.expireEndpoints(now_ns);
        return expired;
    }

    pub fn receive(self: *SecureDatagramHandshakeServer, endpoint: SecureDatagramHandshakeEndpoint, message: handshake.SecureDatagramHandshakeMessage, now_ns: u64) SecureDatagramHandshakeServerError!SecureDatagramHandshakeServerResult {
        _ = self.expire(now_ns);
        return switch (message) {
            .hello => |hello| self.receiveHello(endpoint, hello, now_ns),
            .proof => |proof| self.receiveProof(endpoint, proof, now_ns),
            .challenge, .accept => .ignored,
        };
    }

    fn receiveHello(self: *SecureDatagramHandshakeServer, endpoint: SecureDatagramHandshakeEndpoint, hello: handshake.SecureDatagramHello, now_ns: u64) SecureDatagramHandshakeServerError!SecureDatagramHandshakeServerResult {
        if (hello.session_id == 0) return .ignored;
        if (self.findPending(endpoint, hello.session_id)) |index| {
            const current = self.pending[index].handshake;
            const client_nonce = current.client_nonce orelse return .ignored;
            const server_nonce = current.server_nonce orelse return .ignored;
            if (!std.crypto.timing_safe.eql([psk.psk_challenge_nonce_bytes]u8, client_nonce, hello.client_nonce)) return .ignored;
            return .{ .response = .{ .challenge = .{ .session_id = hello.session_id, .client_nonce = client_nonce, .server_nonce = server_nonce } } };
        }
        if (self.pending_count == self.pending.len) return .pending_capacity_reached;
        if (!self.allowEndpoint(endpoint, now_ns)) return if (self.findEndpoint(endpoint) == null) .endpoint_capacity_reached else .rate_limited;
        var pending = try handshake.SecureDatagramHandshake.init(.{ .role = .responder, .session_id = hello.session_id, .timeout_ns = self.policy.pending_session_timeout_ns }, self.key.bytes[0..self.key.length]);
        errdefer pending.deinit();
        const response = (try pending.receive(.{ .hello = hello }, now_ns)) orelse {
            pending.deinit();
            return .ignored;
        };
        self.pending[self.pending_count] = .{ .endpoint = endpoint, .session_id = hello.session_id, .handshake = pending };
        self.pending_count += 1;
        return .{ .response = response };
    }

    fn receiveProof(self: *SecureDatagramHandshakeServer, endpoint: SecureDatagramHandshakeEndpoint, proof: handshake.SecureDatagramProof, now_ns: u64) SecureDatagramHandshakeServerError!SecureDatagramHandshakeServerResult {
        const index = self.findPending(endpoint, proof.session_id) orelse return .ignored;
        const response = self.pending[index].handshake.receive(.{ .proof = proof }, now_ns) catch |err| {
            self.removePending(index);
            return err;
        } orelse return .ignored;
        if (self.pending[index].handshake.state != .authenticated) return .{ .response = response };
        const completed = self.takePending(index);
        return .{ .authenticated = .{ .endpoint = completed.endpoint, .response = response, .handshake = completed.handshake } };
    }

    fn allowEndpoint(self: *SecureDatagramHandshakeServer, endpoint: SecureDatagramHandshakeEndpoint, now_ns: u64) bool {
        const index = self.findEndpoint(endpoint) orelse blk: {
            if (self.endpoint_count == self.endpoints.len) return false;
            self.endpoints[self.endpoint_count] = .{ .endpoint = endpoint, .tokens = self.policy.endpoint_burst, .last_refill_ns = now_ns, .last_seen_ns = now_ns };
            self.endpoint_count += 1;
            break :blk self.endpoint_count - 1;
        };
        var bucket = &self.endpoints[index];
        if (now_ns >= bucket.last_refill_ns) {
            const elapsed = now_ns - bucket.last_refill_ns;
            const replenished = elapsed / self.policy.endpoint_refill_interval_ns;
            if (replenished != 0) {
                if (replenished >= @as(u64, self.policy.endpoint_burst - bucket.tokens)) {
                    bucket.tokens = self.policy.endpoint_burst;
                    bucket.last_refill_ns = now_ns;
                } else {
                    bucket.tokens += @intCast(replenished);
                    bucket.last_refill_ns += replenished * self.policy.endpoint_refill_interval_ns;
                }
            }
        }
        if (now_ns >= bucket.last_seen_ns) bucket.last_seen_ns = now_ns;
        if (bucket.tokens == 0) return false;
        bucket.tokens -= 1;
        return true;
    }

    fn expireEndpoints(self: *SecureDatagramHandshakeServer, now_ns: u64) void {
        var index: usize = 0;
        while (index < self.endpoint_count) {
            const bucket = self.endpoints[index];
            if (self.hasPendingForEndpoint(bucket.endpoint) or now_ns < bucket.last_seen_ns or now_ns - bucket.last_seen_ns < self.policy.endpoint_idle_timeout_ns) {
                index += 1;
                continue;
            }
            self.endpoint_count -= 1;
            if (index != self.endpoint_count) self.endpoints[index] = self.endpoints[self.endpoint_count];
        }
    }

    fn findPending(self: *const SecureDatagramHandshakeServer, endpoint: SecureDatagramHandshakeEndpoint, session_id: u64) ?usize {
        for (self.pending[0..self.pending_count], 0..) |entry, index| if (entry.endpoint == endpoint and entry.session_id == session_id) return index;
        return null;
    }

    fn findEndpoint(self: *const SecureDatagramHandshakeServer, endpoint: SecureDatagramHandshakeEndpoint) ?usize {
        for (self.endpoints[0..self.endpoint_count], 0..) |bucket, index| if (bucket.endpoint == endpoint) return index;
        return null;
    }

    fn hasPendingForEndpoint(self: *const SecureDatagramHandshakeServer, endpoint: SecureDatagramHandshakeEndpoint) bool {
        for (self.pending[0..self.pending_count]) |entry| if (entry.endpoint == endpoint) return true;
        return false;
    }

    fn removePending(self: *SecureDatagramHandshakeServer, index: usize) void {
        var removed = self.takePending(index);
        removed.handshake.deinit();
    }

    fn takePending(self: *SecureDatagramHandshakeServer, index: usize) PendingSession {
        const result = self.pending[index];
        self.pending_count -= 1;
        if (index != self.pending_count) self.pending[index] = self.pending[self.pending_count];
        return result;
    }
};

test "secure datagram handshake policy bounds pending flood and expires storage" {
    const key = [_]u8{7} ** 32;
    var server = try SecureDatagramHandshakeServer.init(std.testing.allocator, .{ .maximum_pending_sessions = 2, .maximum_endpoints = 8, .endpoint_burst = 1, .endpoint_refill_interval_ns = 5, .pending_session_timeout_ns = 5, .endpoint_idle_timeout_ns = 10 }, key[0..]);
    defer server.deinit();
    const nonce = [_]u8{3} ** psk.psk_challenge_nonce_bytes;
    inline for ([_]u64{ 1, 2 }) |session_id| {
        const result = try server.receive(session_id, .{ .hello = .{ .session_id = session_id, .client_nonce = nonce } }, 0);
        try std.testing.expect(result == .response);
    }
    inline for ([_]u64{ 3, 4, 5, 6 }) |session_id| {
        const result = try server.receive(session_id, .{ .hello = .{ .session_id = session_id, .client_nonce = nonce } }, 0);
        try std.testing.expect(result == .pending_capacity_reached);
        try std.testing.expectEqual(@as(usize, 2), server.pendingSessionCount());
    }
    try std.testing.expectEqual(@as(usize, 2), server.expire(5));
    try std.testing.expectEqual(@as(usize, 0), server.pendingSessionCount());
    try std.testing.expect((try server.receive(3, .{ .hello = .{ .session_id = 7, .client_nonce = nonce } }, 5)) == .response);
}

test "secure datagram handshake policy rate limits endpoints and reclaims buckets" {
    const key = [_]u8{5} ** 32;
    var server = try SecureDatagramHandshakeServer.init(std.testing.allocator, .{ .maximum_pending_sessions = 4, .maximum_endpoints = 1, .endpoint_burst = 1, .endpoint_refill_interval_ns = 5, .pending_session_timeout_ns = 100, .endpoint_idle_timeout_ns = 10 }, key[0..]);
    defer server.deinit();
    const nonce = [_]u8{4} ** psk.psk_challenge_nonce_bytes;
    try std.testing.expect((try server.receive(1, .{ .hello = .{ .session_id = 1, .client_nonce = nonce } }, 0)) == .response);
    try std.testing.expect((try server.receive(1, .{ .hello = .{ .session_id = 2, .client_nonce = nonce } }, 0)) == .rate_limited);
    try std.testing.expect((try server.receive(2, .{ .hello = .{ .session_id = 3, .client_nonce = nonce } }, 0)) == .endpoint_capacity_reached);
    try std.testing.expect((try server.receive(1, .{ .hello = .{ .session_id = 2, .client_nonce = nonce } }, 5)) == .response);
    try std.testing.expectEqual(@as(usize, 2), server.expire(105));
    try std.testing.expectEqual(@as(usize, 0), server.endpointCount());
    try std.testing.expect((try server.receive(2, .{ .hello = .{ .session_id = 3, .client_nonce = nonce } }, 105)) == .response);
}

test "secure datagram handshake policy returns authenticated handoff" {
    const key = [_]u8{9} ** 32;
    var server = try SecureDatagramHandshakeServer.init(std.testing.allocator, .{}, key[0..]);
    defer server.deinit();
    var client = try handshake.SecureDatagramHandshake.init(.{ .role = .initiator, .session_id = 9, .timeout_ns = 50 }, key[0..]);
    defer client.deinit();
    const hello = try client.begin(0);
    const challenge = switch (try server.receive(1, hello, 0)) {
        .response => |response| response,
        else => return error.TestExpectedEqual,
    };
    const proof = (try client.receive(challenge, 0)).?;
    const result = try server.receive(1, proof, 0);
    const authenticated = switch (result) {
        .authenticated => |value| value,
        else => return error.TestExpectedEqual,
    };
    var completed = authenticated.handshake;
    defer completed.deinit();
    try std.testing.expectEqual(@as(SecureDatagramHandshakeEndpoint, 1), authenticated.endpoint);
    try std.testing.expect(authenticated.response == .accept);
    try std.testing.expectEqual(handshake.SecureDatagramHandshakeState.authenticated, completed.state);
    try std.testing.expectEqual(@as(usize, 0), server.pendingSessionCount());
}
