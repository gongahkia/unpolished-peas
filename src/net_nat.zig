const std = @import("std");
const p2p = @import("net_p2p.zig");
const transport = @import("net_transport.zig");

pub const max_candidates: usize = 8;
pub const CandidateKind = enum { host, server_reflexive, relay };
pub const NatPolicy = enum { open, restricted, blocked };
pub const State = enum { idle, gathering, checking, direct, relay, failed };
pub const Diagnostic = enum { candidate_expired, candidate_limit, direct_selected, direct_unreachable, relay_selected, no_route };

pub const Candidate = struct {
    peer: transport.Peer,
    kind: CandidateKind,
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
        return self.candidate(peer, .host, 100, now_ms);
    }

    pub fn serverReflexive(self: Gatherer, observed_peer: transport.Peer, now_ms: u64) !Candidate {
        return self.candidate(observed_peer, .server_reflexive, 200, now_ms);
    }

    pub fn relay(self: Gatherer, relay_peer: transport.Peer, now_ms: u64) !Candidate {
        return self.candidate(relay_peer, .relay, 10, now_ms);
    }

    fn candidate(self: Gatherer, peer: transport.Peer, kind: CandidateKind, priority: u16, now_ms: u64) !Candidate {
        if (peer.id == 0 or now_ms > std.math.maxInt(u64) - self.config.candidate_ttl_ms) return error.InvalidCandidate;
        return .{ .peer = peer, .kind = kind, .priority = priority, .expires_at_ms = now_ms + self.config.candidate_ttl_ms };
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
        if (config.max_attempts == 0) return error.InvalidProbeConfig;
        return .{ .allocator = allocator, .config = config };
    }

    pub fn deinit(self: *Client) void {
        self.local_candidates.deinit(self.allocator);
        self.remote_candidates.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addLocalCandidate(self: *Client, candidate: Candidate) !void {
        try self.add(&self.local_candidates, candidate);
    }

    pub fn addRemoteCandidate(self: *Client, candidate: Candidate) !void {
        try self.add(&self.remote_candidates, candidate);
    }

    pub fn probe(self: *Client, now_ms: u64) !Result {
        if (self.state == .direct) return .{ .route = .direct };
        if (self.state == .relay) return .{ .route = .relay };
        if (self.state == .failed) return .{ .failure = self.diagnostic orelse .no_route };
        self.state = .checking;
        const local = bestCandidate(self.local_candidates.items, now_ms) orelse return self.expiredOrMissing();
        const remote = bestCandidate(self.remote_candidates.items, now_ms) orelse return self.expiredOrMissing();
        _ = local;
        _ = remote;
        if (self.attempts >= self.config.max_attempts) return self.fallback(.direct_unreachable);
        self.attempts += 1;
        if (canReachDirect(self.config.local_policy, self.config.remote_policy)) {
            self.state = .direct;
            self.diagnostic = .direct_selected;
            return .{ .route = .direct };
        }
        return self.fallback(.direct_unreachable);
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

    fn add(self: *Client, candidates: *std.ArrayListUnmanaged(Candidate), candidate: Candidate) !void {
        if (self.state != .idle and self.state != .gathering) return error.InvalidTraversalState;
        if (candidate.peer.id == 0 or candidate.expires_at_ms == 0) return error.InvalidCandidate;
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

    fn fallback(self: *Client, direct_diagnostic: Diagnostic) Result {
        self.diagnostic = direct_diagnostic;
        if (self.config.allow_relay) {
            self.state = .relay;
            self.diagnostic = .relay_selected;
            return .{ .route = .relay };
        }
        self.state = .failed;
        self.diagnostic = .no_route;
        return .{ .failure = .no_route };
    }
};

fn bestCandidate(candidates: []const Candidate, now_ms: u64) ?Candidate {
    var selected: ?Candidate = null;
    for (candidates) |candidate| {
        if (now_ms >= candidate.expires_at_ms) continue;
        if (selected == null or candidate.priority > selected.?.priority) selected = candidate;
    }
    return selected;
}

fn canReachDirect(local: NatPolicy, remote: NatPolicy) bool {
    return local != .blocked and remote != .blocked;
}

fn addGathered(client: *Client, gatherer: Gatherer, now_ms: u64) !void {
    try client.addLocalCandidate(try gatherer.host(.{ .id = 1 }, now_ms));
    try client.addLocalCandidate(try gatherer.serverReflexive(.{ .id = 11 }, now_ms));
    try client.addRemoteCandidate(try gatherer.host(.{ .id = 2 }, now_ms));
    try client.addRemoteCandidate(try gatherer.serverReflexive(.{ .id = 22 }, now_ms));
}

test "simulated NAT matrix selects direct or relay deterministically" {
    const gatherer = try Gatherer.init(.{ .candidate_ttl_ms = 100 });
    for ([_]NatPolicy{ .open, .restricted, .blocked }) |local| for ([_]NatPolicy{ .open, .restricted, .blocked }) |remote| {
        var client = try Client.init(std.testing.allocator, .{ .local_policy = local, .remote_policy = remote });
        defer client.deinit();
        try addGathered(&client, gatherer, 10);
        const result = try client.probe(10);
        const expected: p2p.Route = if (local == .blocked or remote == .blocked) .relay else .direct;
        try std.testing.expectEqual(expected, result.route);
        try std.testing.expectEqual(if (expected == .direct) State.direct else State.relay, client.state);
    };
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
    var client = try Client.init(std.testing.allocator, .{ .local_policy = .open, .remote_policy = .open });
    defer client.deinit();
    try std.testing.expectError(error.InvalidCandidate, client.addLocalCandidate(.{ .peer = .{ .id = 0 }, .kind = .host, .priority = 1, .expires_at_ms = 1 }));
    var index: usize = 0;
    while (index < max_candidates) : (index += 1) try client.addLocalCandidate(try gatherer.host(.{ .id = @intCast(index + 1) }, 0));
    try std.testing.expectError(error.CandidateLimitExceeded, client.addLocalCandidate(try gatherer.host(.{ .id = 99 }, 0)));
}
