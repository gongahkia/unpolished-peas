const std = @import("std");
const guest = @import("guest_credentials.zig");
const lobby = @import("service_lobby.zig");
const matchmaking = @import("service_matchmaking.zig");
const provider = @import("service_provider.zig");
const up = @import("unpolished-peas");

const Status = enum { allocated, expired };
pub const Config = struct {
    max_allocations: usize = 128,
    max_connections_per_allocation: u16 = 2,
    max_bandwidth_bytes_per_allocation: u64 = 4 * 1024 * 1024,
    allocation_lifetime_ms: i64 = 30_000,
};
pub const Bootstrap = struct {
    allocation_id: u64,
    match_id: u64,
    route_token: [32]u8,
    expires_at_ms: i64,
    max_connections: u16,
};
pub const Lease = struct { allocation_id: u64, connection_id: u64 };
const Allocation = struct {
    id: u64,
    match_id: u64,
    route_token: [32]u8,
    expires_at_ms: i64,
    active_connections: u16 = 0,
    transmitted_bytes: u64 = 0,
    status: Status = .allocated,
};
const Connection = struct { id: u64, allocation_id: u64, identity: [32]u8, active: bool = true };

pub const Service = struct { // owns bounded relay allocations and leases; call deinit once.
    allocator: std.mem.Allocator,
    provider: provider.Provider,
    matches: *matchmaking.Service,
    config: Config,
    allocations: std.ArrayListUnmanaged(Allocation) = .{},
    connections: std.ArrayListUnmanaged(Connection) = .{},
    next_allocation_id: u64 = 1,
    next_connection_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator, service_provider: provider.Provider, matches: *matchmaking.Service, config: Config) !Service {
        if (config.max_allocations == 0 or config.max_allocations > 1_024 or config.max_connections_per_allocation == 0 or config.max_connections_per_allocation > 64 or config.max_bandwidth_bytes_per_allocation == 0 or config.allocation_lifetime_ms <= 0) return error.InvalidRelayConfig;
        return .{ .allocator = allocator, .provider = service_provider, .matches = matches, .config = config };
    }

    pub fn deinit(self: *Service) void {
        self.allocations.deinit(self.allocator);
        self.connections.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn bootstrap(self: *Service, request_id: u64, credentials: guest.Credentials, now_ms: i64) !Bootstrap {
        const identity = try self.authenticate(credentials, now_ms);
        const assignment = try self.matches.assignmentForParticipant(request_id, identity);
        self.expire(now_ms);
        for (self.allocations.items) |allocation| {
            if (allocation.match_id == assignment.match_id and allocation.status == .allocated) return self.publicBootstrap(allocation);
        }
        const expires_at_ms = @min(try std.math.add(i64, now_ms, self.config.allocation_lifetime_ms), credentials.expires_at_ms);
        if (expires_at_ms <= now_ms) return error.RelayExpired;
        const allocation = Allocation{ .id = self.nextId(&self.next_allocation_id), .match_id = assignment.match_id, .route_token = guest.Token.generate().bytes, .expires_at_ms = expires_at_ms };
        try self.storeAllocation(allocation);
        return self.publicBootstrap(allocation);
    }

    pub fn open(self: *Service, route: Bootstrap, credentials: guest.Credentials, now_ms: i64) !Lease {
        const identity = try self.authenticate(credentials, now_ms);
        self.expire(now_ms);
        const allocation = self.findAllocation(route.allocation_id) orelse return error.UnknownRelayAllocation;
        try self.authorize(allocation, route, identity);
        if (allocation.active_connections >= self.config.max_connections_per_allocation) return error.RelayConnectionCap;
        const connection = Connection{ .id = self.nextId(&self.next_connection_id), .allocation_id = allocation.id, .identity = identity };
        try self.storeConnection(connection);
        allocation.active_connections += 1;
        return .{ .allocation_id = allocation.id, .connection_id = connection.id };
    }

    pub fn record(self: *Service, lease: Lease, credentials: guest.Credentials, bytes: u64, now_ms: i64) !void {
        const identity = try self.authenticate(credentials, now_ms);
        self.expire(now_ms);
        const connection = self.findConnection(lease) orelse return error.UnknownRelayLease;
        if (!connection.active or !std.crypto.timing_safe.eql([32]u8, connection.identity, identity)) return error.RelayForbidden;
        const allocation = self.findAllocation(lease.allocation_id) orelse return error.UnknownRelayAllocation;
        if (allocation.status != .allocated) return error.RelayExpired;
        const total = std.math.add(u64, allocation.transmitted_bytes, bytes) catch return error.RelayBandwidthCap;
        if (total > self.config.max_bandwidth_bytes_per_allocation) return error.RelayBandwidthCap;
        allocation.transmitted_bytes = total;
    }

    pub fn close(self: *Service, lease: Lease, credentials: guest.Credentials, now_ms: i64) !void {
        const identity = try self.authenticate(credentials, now_ms);
        self.expire(now_ms);
        const connection = self.findConnection(lease) orelse return error.UnknownRelayLease;
        if (!connection.active or !std.crypto.timing_safe.eql([32]u8, connection.identity, identity)) return error.RelayForbidden;
        connection.active = false;
        const allocation = self.findAllocation(lease.allocation_id) orelse return error.UnknownRelayAllocation;
        if (allocation.active_connections > 0) allocation.active_connections -= 1;
    }

    pub fn expire(self: *Service, now_ms: i64) void {
        for (self.allocations.items) |*allocation| {
            if (allocation.status == .allocated and now_ms >= allocation.expires_at_ms) {
                allocation.status = .expired;
                allocation.active_connections = 0;
                for (self.connections.items) |*connection| {
                    if (connection.allocation_id == allocation.id) connection.active = false;
                }
            }
        }
    }

    fn authenticate(self: *Service, credentials: guest.Credentials, now_ms: i64) ![32]u8 {
        if (!credentials.active(now_ms)) return error.GuestSessionExpired;
        if (try self.provider.validateGuestSession(credentials.session) != .active) return error.GuestSessionRejected;
        return credentials.identity.hash();
    }

    fn authorize(self: *Service, allocation: *Allocation, route: Bootstrap, identity: [32]u8) !void {
        if (allocation.status != .allocated) return error.RelayExpired;
        if (allocation.match_id != route.match_id or allocation.expires_at_ms != route.expires_at_ms or route.max_connections != self.config.max_connections_per_allocation or !std.crypto.timing_safe.eql([32]u8, allocation.route_token, route.route_token)) return error.RelayForbidden;
        if (!self.matches.isParticipant(allocation.match_id, identity)) return error.RelayForbidden;
    }

    fn publicBootstrap(self: *const Service, allocation: Allocation) Bootstrap {
        return .{ .allocation_id = allocation.id, .match_id = allocation.match_id, .route_token = allocation.route_token, .expires_at_ms = allocation.expires_at_ms, .max_connections = self.config.max_connections_per_allocation };
    }

    fn storeAllocation(self: *Service, allocation: Allocation) !void {
        for (self.allocations.items) |*slot| {
            if (slot.status != .allocated) {
                slot.* = allocation;
                return;
            }
        }
        if (self.allocations.items.len >= self.config.max_allocations) return error.RelayAllocationCap;
        try self.allocations.append(self.allocator, allocation);
    }

    fn storeConnection(self: *Service, connection: Connection) !void {
        for (self.connections.items) |*slot| {
            if (!slot.active) {
                slot.* = connection;
                return;
            }
        }
        const capacity = @as(usize, self.config.max_connections_per_allocation) * self.config.max_allocations;
        if (self.connections.items.len >= capacity) return error.RelayConnectionCap;
        try self.connections.append(self.allocator, connection);
    }

    fn findAllocation(self: *Service, id: u64) ?*Allocation {
        for (self.allocations.items) |*allocation| if (allocation.id == id) return allocation;
        return null;
    }

    fn findConnection(self: *Service, lease: Lease) ?*Connection {
        for (self.connections.items) |*connection| if (connection.id == lease.connection_id and connection.allocation_id == lease.allocation_id) return connection;
        return null;
    }

    fn nextId(self: *Service, counter: *u64) u64 {
        _ = self;
        const id = counter.*;
        counter.* +%= 1;
        if (counter.* == 0) counter.* = 1;
        return id;
    }
};

const MatchedParticipants = struct {
    fake: provider.FakeAdapter = .{},
    lobbies: lobby.Service = undefined,
    matches: matchmaking.Service = undefined,
    host: guest.Credentials = undefined,
    client: guest.Credentials = undefined,
    intruder: guest.Credentials = undefined,
    host_request_id: u64 = undefined,
    client_request_id: u64 = undefined,

    fn init(self: *MatchedParticipants, allocator: std.mem.Allocator) !void {
        const service_provider = self.fake.provider();
        self.lobbies = try lobby.Service.init(allocator, service_provider, .{});
        errdefer self.lobbies.deinit();
        self.matches = try matchmaking.Service.init(allocator, &self.lobbies, .{});
        errdefer self.matches.deinit();
        self.host = try service_provider.issueGuestSession(.{ .now_ms = 1, .lifetime_ms = 100 });
        self.client = try service_provider.issueGuestSession(.{ .now_ms = 1, .lifetime_ms = 100 });
        self.intruder = try service_provider.issueGuestSession(.{ .now_ms = 1, .lifetime_ms = 100 });
        const room = try self.lobbies.create(self.host, 2, 100, 1);
        try self.lobbies.join(room.id, self.client, 1);
        self.host_request_id = (try self.matches.enqueue(room.id, self.host, 1)).id;
        self.client_request_id = (try self.matches.enqueue(room.id, self.client, 1)).id;
        _ = (try self.matches.matchNext(1)) orelse return error.TestExpectedEqual;
    }

    fn deinit(self: *MatchedParticipants) void {
        self.matches.deinit();
        self.lobbies.deinit();
    }
};

test "relay allocation enforces participant authorization and expiry" {
    var participants: MatchedParticipants = undefined;
    try participants.init(std.testing.allocator);
    defer participants.deinit();
    const service_provider = participants.fake.provider();
    var relay = try Service.init(std.testing.allocator, service_provider, &participants.matches, .{ .max_allocations = 1, .max_connections_per_allocation = 2, .max_bandwidth_bytes_per_allocation = 32, .allocation_lifetime_ms = 5 });
    defer relay.deinit();
    try std.testing.expectError(error.MatchRequestForbidden, relay.bootstrap(participants.host_request_id, participants.intruder, 1));
    const host_bootstrap = try relay.bootstrap(participants.host_request_id, participants.host, 1);
    const client_bootstrap = try relay.bootstrap(participants.client_request_id, participants.client, 1);
    try std.testing.expectEqual(host_bootstrap.allocation_id, client_bootstrap.allocation_id);
    try std.testing.expect(std.crypto.timing_safe.eql([32]u8, host_bootstrap.route_token, client_bootstrap.route_token));
    const second_host = try service_provider.issueGuestSession(.{ .now_ms = 1, .lifetime_ms = 100 });
    const second_client = try service_provider.issueGuestSession(.{ .now_ms = 1, .lifetime_ms = 100 });
    const second_room = try participants.lobbies.create(second_host, 2, 100, 1);
    try participants.lobbies.join(second_room.id, second_client, 1);
    const second_request = try participants.matches.enqueue(second_room.id, second_host, 1);
    _ = try participants.matches.enqueue(second_room.id, second_client, 1);
    _ = (try participants.matches.matchNext(1)) orelse return error.TestExpectedEqual;
    try std.testing.expectError(error.RelayAllocationCap, relay.bootstrap(second_request.id, second_host, 1));
    try std.testing.expectError(error.RelayForbidden, relay.open(host_bootstrap, participants.intruder, 2));
    _ = try relay.open(host_bootstrap, participants.host, 2);
    _ = try relay.open(client_bootstrap, participants.client, 2);
    try std.testing.expectError(error.RelayConnectionCap, relay.open(host_bootstrap, participants.host, 2));
    try std.testing.expectError(error.RelayExpired, relay.open(host_bootstrap, participants.host, 6));
}

test "relay allocation enforces bandwidth and bounded lease reuse" {
    var participants: MatchedParticipants = undefined;
    try participants.init(std.testing.allocator);
    defer participants.deinit();
    const service_provider = participants.fake.provider();
    var relay = try Service.init(std.testing.allocator, service_provider, &participants.matches, .{ .max_allocations = 1, .max_connections_per_allocation = 1, .max_bandwidth_bytes_per_allocation = 5, .allocation_lifetime_ms = 10 });
    defer relay.deinit();
    const bootstrap = try relay.bootstrap(participants.host_request_id, participants.host, 1);
    const lease = try relay.open(bootstrap, participants.host, 1);
    try relay.record(lease, participants.host, 5, 1);
    try std.testing.expectError(error.RelayBandwidthCap, relay.record(lease, participants.host, 1, 1));
    try relay.close(lease, participants.host, 1);
    const replacement = try relay.open(bootstrap, participants.client, 1);
    try std.testing.expect(replacement.connection_id != lease.connection_id);
}

test "relay fallback fixture transfers game packets" {
    var participants: MatchedParticipants = undefined;
    try participants.init(std.testing.allocator);
    defer participants.deinit();
    const service_provider = participants.fake.provider();
    var relay = try Service.init(std.testing.allocator, service_provider, &participants.matches, .{ .max_bandwidth_bytes_per_allocation = 64, .allocation_lifetime_ms = 50 });
    defer relay.deinit();
    const bootstrap = try relay.bootstrap(participants.host_request_id, participants.host, 1);
    const host_lease = try relay.open(bootstrap, participants.host, 1);
    const client_lease = try relay.open(bootstrap, participants.client, 1);
    defer relay.close(client_lease, participants.client, 1) catch {};
    defer relay.close(host_lease, participants.host, 1) catch {};
    var host_endpoint = up.LoopbackTransport.init(std.testing.allocator, .{ .id = 1 });
    defer host_endpoint.deinit();
    var client_endpoint = up.LoopbackTransport.init(std.testing.allocator, .{ .id = 2 });
    defer client_endpoint.deinit();
    up.LoopbackTransport.pair(&host_endpoint, &client_endpoint);
    const host_identity = try up.NetIdentity.init(1);
    const client_identity = try up.NetIdentity.init(2);
    const authentication_token = std.mem.readInt(u64, bootstrap.route_token[0..8], .little) | 1;
    var host_peer = try up.P2pPeer.init(std.testing.allocator, .{ .local_identity = host_identity, .remote_identity = client_identity, .session_id = bootstrap.match_id, .authentication_token = authentication_token, .expires_at_ms = @intCast(bootstrap.expires_at_ms), .peer = .{ .id = 2 }, .route = .relay });
    defer host_peer.deinit();
    var client_peer = try up.P2pPeer.init(std.testing.allocator, .{ .local_identity = client_identity, .remote_identity = host_identity, .session_id = bootstrap.match_id, .authentication_token = authentication_token, .expires_at_ms = @intCast(bootstrap.expires_at_ms), .peer = .{ .id = 1 }, .route = .relay });
    defer client_peer.deinit();
    try host_peer.begin(host_endpoint.transport());
    try client_peer.begin(client_endpoint.transport());
    try host_peer.poll(host_endpoint.transport());
    try client_peer.poll(client_endpoint.transport());
    try host_peer.poll(host_endpoint.transport());
    try client_peer.poll(client_endpoint.transport());
    const packet = "fallback-game-packet";
    try client_peer.sendReliable(client_endpoint.transport(), packet);
    try relay.record(client_lease, participants.client, packet.len, 1);
    try host_peer.poll(host_endpoint.transport());
    var received = host_peer.receive() orelse return error.TestExpectedEqual;
    defer received.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(packet, received.payload);
}
