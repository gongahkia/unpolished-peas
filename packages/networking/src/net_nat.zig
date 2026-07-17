const std = @import("std");

const p2p = @import("net_p2p.zig");
const transport = @import("net_transport.zig");

pub const max_candidates: usize = 8;
pub const CandidateKind = enum { host, server_reflexive, relay };
pub const AddressFamily = enum { ipv4, ipv6 };
pub const AddressFamilies = struct {
    ipv4: bool = true,
    ipv6: bool = false,

    pub fn supports(self: AddressFamilies, family: AddressFamily) bool {
        return switch (family) {
            .ipv4 => self.ipv4,
            .ipv6 => self.ipv6,
        };
    }

    pub fn empty(self: AddressFamilies) bool {
        return !self.ipv4 and !self.ipv6;
    }
};
pub const NatPolicy = enum { open, restricted, symmetric, blocked };
pub const State = enum { idle, gathering, checking, direct, relay, failed };
pub const Diagnostic = enum { candidate_expired, candidate_limit, direct_selected, direct_unreachable, address_family_mismatch, stun_unavailable, relay_selected, turn_unavailable, no_route };

pub const Candidate = struct {
    peer: transport.Peer,
    kind: CandidateKind,
    family: AddressFamily = .ipv4,
    priority: u16,
    expires_at_ms: u64,
};

pub const GatherConfig = struct {
    candidate_ttl_ms: u64 = 30_000,
    max_candidates: usize = 4,
};

pub const ProbeConfig = struct {
    local_policy: NatPolicy,
    remote_policy: NatPolicy,
    allow_relay: bool = true,
    local_families: AddressFamilies = .{},
    remote_families: AddressFamilies = .{},
    stun_available: bool = true,
    turn_available: bool = true,
    max_attempts: u8 = 3,
};

pub const Result = union(enum) { route: p2p.Route, failure: Diagnostic };

pub const Gatherer = struct {
    config: GatherConfig,

    pub fn init(config: GatherConfig) !Gatherer {
        if (config.candidate_ttl_ms == 0 or config.max_candidates == 0 or config.max_candidates > max_candidates) return error.InvalidCandidateConfig;
        return .{ .config = config };
    }

    pub fn host(self: Gatherer, peer: transport.Peer, now_ms: u64) !Candidate {
        return self.hostForFamily(peer, .ipv4, now_ms);
    }

    pub fn serverReflexive(self: Gatherer, observed_peer: transport.Peer, now_ms: u64) !Candidate {
        return self.serverReflexiveForFamily(observed_peer, .ipv4, now_ms);
    }

    pub fn relay(self: Gatherer, relay_peer: transport.Peer, now_ms: u64) !Candidate {
        return self.relayForFamily(relay_peer, .ipv4, now_ms);
    }

    pub fn hostForFamily(self: Gatherer, peer: transport.Peer, family: AddressFamily, now_ms: u64) !Candidate {
        return self.candidate(peer, .host, family, 100, now_ms);
    }

    pub fn serverReflexiveForFamily(self: Gatherer, observed_peer: transport.Peer, family: AddressFamily, now_ms: u64) !Candidate {
        return self.candidate(observed_peer, .server_reflexive, family, 200, now_ms);
    }

    pub fn relayForFamily(self: Gatherer, relay_peer: transport.Peer, family: AddressFamily, now_ms: u64) !Candidate {
        return self.candidate(relay_peer, .relay, family, 10, now_ms);
    }

    fn candidate(self: Gatherer, peer: transport.Peer, kind: CandidateKind, family: AddressFamily, priority: u16, now_ms: u64) !Candidate {
        if (peer.id == 0 or now_ms > std.math.maxInt(u64) - self.config.candidate_ttl_ms) return error.InvalidCandidate;
        return .{ .peer = peer, .kind = kind, .family = family, .priority = priority, .expires_at_ms = now_ms + self.config.candidate_ttl_ms };
    }
};

pub const Client = struct { // owns copied candidate lists; call deinit once.
    allocator: std.mem.Allocator,
    config: ProbeConfig,
    state: State = .idle,
    diagnostic: ?Diagnostic = null,
    attempts: u8 = 0,
    local_candidates: std.ArrayListUnmanaged(Candidate) = .{},
    remote_candidates: std.ArrayListUnmanaged(Candidate) = .{},

    pub fn init(allocator: std.mem.Allocator, config: ProbeConfig) !Client {
        if (config.max_attempts == 0 or config.local_families.empty() or config.remote_families.empty()) return error.InvalidProbeConfig;
        return .{ .allocator = allocator, .config = config };
    }

    pub fn deinit(self: *Client) void {
        self.local_candidates.deinit(self.allocator);
        self.remote_candidates.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addLocalCandidate(self: *Client, candidate: Candidate) !void {
        try self.add(&self.local_candidates, self.config.local_families, candidate);
    }

    pub fn addRemoteCandidate(self: *Client, candidate: Candidate) !void {
        try self.add(&self.remote_candidates, self.config.remote_families, candidate);
    }

    pub fn probe(self: *Client, now_ms: u64) !Result {
        if (self.state == .direct) return .{ .route = .direct };
        if (self.state == .relay) return .{ .route = .relay };
        if (self.state == .failed) return .{ .failure = self.diagnostic orelse .no_route };
        self.state = .checking;
        if (!hasLiveCandidate(self.local_candidates.items, now_ms) or !hasLiveCandidate(self.remote_candidates.items, now_ms)) return self.expiredOrMissing();
        if (self.attempts >= self.config.max_attempts) return self.fallback(.direct_unreachable, now_ms);
        self.attempts += 1;
        if (self.hasDirectPair(now_ms) and canReachDirect(self.config.local_policy, self.config.remote_policy)) {
            self.state = .direct;
            self.diagnostic = .direct_selected;
            return .{ .route = .direct };
        }
        return self.fallback(self.directFailure(now_ms), now_ms);
    }

    pub fn selectRoute(self: *Client, now_ms: u64) !p2p.Route {
        return switch (try self.probe(now_ms)) {
            .route => |route| route,
            .failure => |diagnostic| switch (diagnostic) {
                .candidate_expired => error.CandidateExpired,
                else => error.DirectRouteUnavailable,
            },
        };
    }

    fn add(self: *Client, candidates: *std.ArrayListUnmanaged(Candidate), families: AddressFamilies, candidate: Candidate) !void {
        if (self.state != .idle and self.state != .gathering) return error.InvalidTraversalState;
        if (candidate.peer.id == 0 or candidate.expires_at_ms == 0 or !families.supports(candidate.family)) return error.InvalidCandidate;
        if (candidates.items.len >= max_candidates) {
            self.diagnostic = .candidate_limit;
            return error.CandidateLimitExceeded;
        }
        self.state = .gathering;
        try candidates.append(self.allocator, candidate);
    }

    fn expiredOrMissing(self: *Client) Result {
        self.state = .failed;
        self.diagnostic = if (self.local_candidates.items.len == 0 or self.remote_candidates.items.len == 0) .no_route else .candidate_expired;
        return .{ .failure = self.diagnostic.? };
    }

    fn fallback(self: *Client, direct_diagnostic: Diagnostic, now_ms: u64) Result {
        self.diagnostic = direct_diagnostic;
        if (self.config.allow_relay and self.config.turn_available and self.hasRelayCandidate(now_ms)) {
            self.state = .relay;
            self.diagnostic = .relay_selected;
            return .{ .route = .relay };
        }
        self.state = .failed;
        self.diagnostic = if (self.config.allow_relay and !self.config.turn_available) .turn_unavailable else .no_route;
        return .{ .failure = self.diagnostic.? };
    }

    fn hasDirectPair(self: Client, now_ms: u64) bool {
        for (self.local_candidates.items) |local| {
            if (!isDirectCandidate(local, self.config.local_families, self.config.stun_available, now_ms)) continue;
            for (self.remote_candidates.items) |remote| {
                if (local.family == remote.family and isDirectCandidate(remote, self.config.remote_families, self.config.stun_available, now_ms)) return true;
            }
        }
        return false;
    }

    fn hasRelayCandidate(self: Client, now_ms: u64) bool {
        for (self.local_candidates.items) |candidate| if (isRelayCandidate(candidate, self.config.local_families, self.config.remote_families, now_ms)) return true;
        for (self.remote_candidates.items) |candidate| if (isRelayCandidate(candidate, self.config.remote_families, self.config.local_families, now_ms)) return true;
        return false;
    }

    fn directFailure(self: Client, now_ms: u64) Diagnostic {
        if (!self.config.stun_available and self.hasStunPair(now_ms)) return .stun_unavailable;
        return if (self.hasFamilyPair(now_ms)) .direct_unreachable else .address_family_mismatch;
    }

    fn hasStunPair(self: Client, now_ms: u64) bool {
        for (self.local_candidates.items) |local| {
            if (!isDirectCandidate(local, self.config.local_families, true, now_ms)) continue;
            for (self.remote_candidates.items) |remote| {
                if (local.family == remote.family and isDirectCandidate(remote, self.config.remote_families, true, now_ms) and (local.kind == .server_reflexive or remote.kind == .server_reflexive)) return true;
            }
        }
        return false;
    }

    fn hasFamilyPair(self: Client, now_ms: u64) bool {
        for (self.local_candidates.items) |local| {
            if (!isDirectCandidate(local, self.config.local_families, true, now_ms)) continue;
            for (self.remote_candidates.items) |remote| {
                if (local.family == remote.family and isDirectCandidate(remote, self.config.remote_families, true, now_ms)) return true;
            }
        }
        return false;
    }
};

fn hasLiveCandidate(candidates: []const Candidate, now_ms: u64) bool {
    for (candidates) |candidate| if (now_ms < candidate.expires_at_ms) return true;
    return false;
}

fn isCandidateLive(candidate: Candidate, families: AddressFamilies, now_ms: u64) bool {
    return now_ms < candidate.expires_at_ms and families.supports(candidate.family);
}

fn isDirectCandidate(candidate: Candidate, families: AddressFamilies, stun_available: bool, now_ms: u64) bool {
    if (!isCandidateLive(candidate, families, now_ms)) return false;
    return switch (candidate.kind) {
        .host => true,
        .server_reflexive => stun_available,
        .relay => false,
    };
}

fn isRelayCandidate(candidate: Candidate, local_families: AddressFamilies, remote_families: AddressFamilies, now_ms: u64) bool {
    return candidate.kind == .relay and isCandidateLive(candidate, local_families, now_ms) and remote_families.supports(candidate.family);
}

fn canReachDirect(local: NatPolicy, remote: NatPolicy) bool {
    return switch (local) {
        .open, .restricted => switch (remote) {
            .open, .restricted => true,
            .symmetric, .blocked => false,
        },
        .symmetric, .blocked => false,
    };
}

fn addGathered(client: *Client, gatherer: Gatherer, now_ms: u64) !void {
    try client.addLocalCandidate(try gatherer.host(.{ .id = 1 }, now_ms));
    try client.addLocalCandidate(try gatherer.serverReflexive(.{ .id = 11 }, now_ms));
    try client.addLocalCandidate(try gatherer.relay(.{ .id = 111 }, now_ms));
    try client.addRemoteCandidate(try gatherer.host(.{ .id = 2 }, now_ms));
    try client.addRemoteCandidate(try gatherer.serverReflexive(.{ .id = 22 }, now_ms));
}

test "simulated NAT policy matrix selects direct or TURN relay deterministically" {
    const gatherer = try Gatherer.init(.{ .candidate_ttl_ms = 100 });
    for ([_]NatPolicy{ .open, .restricted, .symmetric, .blocked }) |local| for ([_]NatPolicy{ .open, .restricted, .symmetric, .blocked }) |remote| {
        var client = try Client.init(std.testing.allocator, .{ .local_policy = local, .remote_policy = remote });
        defer client.deinit();
        try addGathered(&client, gatherer, 10);
        const result = try client.probe(10);
        const expected: p2p.Route = if (canReachDirect(local, remote)) .direct else .relay;
        try std.testing.expectEqual(expected, result.route);
        try std.testing.expectEqual(if (expected == .direct) State.direct else State.relay, client.state);
    };
}

test "simulated NAT matrix models IPv4 IPv6 and dual-stack direct pairs" {
    const gatherer = try Gatherer.init(.{ .candidate_ttl_ms = 100 });
    var ipv4 = try Client.init(std.testing.allocator, .{ .local_policy = .open, .remote_policy = .open });
    defer ipv4.deinit();
    try ipv4.addLocalCandidate(try gatherer.hostForFamily(.{ .id = 1 }, .ipv4, 10));
    try ipv4.addRemoteCandidate(try gatherer.hostForFamily(.{ .id = 2 }, .ipv4, 10));
    try std.testing.expectEqual(p2p.Route.direct, (try ipv4.probe(10)).route);

    var ipv6 = try Client.init(std.testing.allocator, .{ .local_policy = .open, .remote_policy = .open, .local_families = .{ .ipv4 = false, .ipv6 = true }, .remote_families = .{ .ipv4 = false, .ipv6 = true } });
    defer ipv6.deinit();
    try ipv6.addLocalCandidate(try gatherer.hostForFamily(.{ .id = 3 }, .ipv6, 10));
    try ipv6.addRemoteCandidate(try gatherer.hostForFamily(.{ .id = 4 }, .ipv6, 10));
    try std.testing.expectEqual(p2p.Route.direct, (try ipv6.probe(10)).route);

    var dual_stack = try Client.init(std.testing.allocator, .{ .local_policy = .open, .remote_policy = .restricted, .local_families = .{ .ipv4 = true, .ipv6 = true }, .remote_families = .{ .ipv4 = true, .ipv6 = true } });
    defer dual_stack.deinit();
    try dual_stack.addLocalCandidate(try gatherer.hostForFamily(.{ .id = 5 }, .ipv4, 10));
    try dual_stack.addLocalCandidate(try gatherer.hostForFamily(.{ .id = 6 }, .ipv6, 10));
    try dual_stack.addRemoteCandidate(try gatherer.hostForFamily(.{ .id = 7 }, .ipv6, 10));
    try std.testing.expectEqual(p2p.Route.direct, (try dual_stack.probe(10)).route);
}

test "simulated NAT matrix models STUN availability and route fallback failure" {
    const gatherer = try Gatherer.init(.{ .candidate_ttl_ms = 100 });
    var stun = try Client.init(std.testing.allocator, .{ .local_policy = .restricted, .remote_policy = .restricted });
    defer stun.deinit();
    try stun.addLocalCandidate(try gatherer.serverReflexive(.{ .id = 1 }, 10));
    try stun.addRemoteCandidate(try gatherer.serverReflexive(.{ .id = 2 }, 10));
    try std.testing.expectEqual(p2p.Route.direct, (try stun.probe(10)).route);

    var relay = try Client.init(std.testing.allocator, .{ .local_policy = .restricted, .remote_policy = .restricted, .stun_available = false });
    defer relay.deinit();
    try relay.addLocalCandidate(try gatherer.serverReflexive(.{ .id = 3 }, 10));
    try relay.addLocalCandidate(try gatherer.relay(.{ .id = 4 }, 10));
    try relay.addRemoteCandidate(try gatherer.serverReflexive(.{ .id = 5 }, 10));
    try std.testing.expectEqual(p2p.Route.relay, (try relay.probe(10)).route);

    var no_turn = try Client.init(std.testing.allocator, .{ .local_policy = .symmetric, .remote_policy = .open, .turn_available = false });
    defer no_turn.deinit();
    try addGathered(&no_turn, gatherer, 10);
    const result = try no_turn.probe(10);
    try std.testing.expectEqual(Diagnostic.turn_unavailable, result.failure);
    try std.testing.expectEqual(State.failed, no_turn.state);
}

test "simulated NAT matrix falls back from an address-family mismatch through TURN" {
    const gatherer = try Gatherer.init(.{ .candidate_ttl_ms = 100 });
    var client = try Client.init(std.testing.allocator, .{ .local_policy = .open, .remote_policy = .open, .remote_families = .{ .ipv4 = true, .ipv6 = true } });
    defer client.deinit();
    try client.addLocalCandidate(try gatherer.hostForFamily(.{ .id = 1 }, .ipv4, 10));
    try client.addLocalCandidate(try gatherer.relayForFamily(.{ .id = 2 }, .ipv4, 10));
    try client.addRemoteCandidate(try gatherer.hostForFamily(.{ .id = 3 }, .ipv6, 10));
    try std.testing.expectEqual(p2p.Route.relay, (try client.probe(10)).route);
    try std.testing.expectEqual(Diagnostic.relay_selected, client.diagnostic.?);
}

test "candidates expire and unavailable routes report stable diagnostics" {
    const gatherer = try Gatherer.init(.{ .candidate_ttl_ms = 5 });
    var expired = try Client.init(std.testing.allocator, .{ .local_policy = .open, .remote_policy = .open });
    defer expired.deinit();
    try addGathered(&expired, gatherer, 10);
    const expired_result = try expired.probe(15);
    try std.testing.expectEqual(Diagnostic.candidate_expired, expired_result.failure);
    try std.testing.expectEqual(State.failed, expired.state);
    var unavailable = try Client.init(std.testing.allocator, .{ .local_policy = .blocked, .remote_policy = .open, .allow_relay = false });
    defer unavailable.deinit();
    try addGathered(&unavailable, gatherer, 10);
    try std.testing.expectError(error.DirectRouteUnavailable, unavailable.selectRoute(10));
    try std.testing.expectEqual(Diagnostic.no_route, unavailable.diagnostic.?);
    try std.testing.expectEqual(State.failed, unavailable.state);
}

test "candidate collection rejects abusive bounded input" {
    const gatherer = try Gatherer.init(.{ .candidate_ttl_ms = 10 });
    try std.testing.expectError(error.InvalidProbeConfig, Client.init(std.testing.allocator, .{ .local_policy = .open, .remote_policy = .open, .local_families = .{ .ipv4 = false }, .remote_families = .{ .ipv4 = false } }));
    var client = try Client.init(std.testing.allocator, .{ .local_policy = .open, .remote_policy = .open });
    defer client.deinit();
    try std.testing.expectError(error.InvalidCandidate, client.addLocalCandidate(.{ .peer = .{ .id = 0 }, .kind = .host, .priority = 1, .expires_at_ms = 1 }));
    try std.testing.expectError(error.InvalidCandidate, client.addLocalCandidate(try gatherer.hostForFamily(.{ .id = 1 }, .ipv6, 0)));
    var index: usize = 0;
    while (index < max_candidates) : (index += 1) try client.addLocalCandidate(try gatherer.host(.{ .id = @intCast(index + 1) }, 0));
    try std.testing.expectError(error.CandidateLimitExceeded, client.addLocalCandidate(try gatherer.host(.{ .id = 99 }, 0)));
}
