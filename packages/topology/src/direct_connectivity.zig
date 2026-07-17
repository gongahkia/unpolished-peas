const std = @import("std");
const candidates = @import("nat_candidate.zig");

pub const ConnectivityRole = enum { controlling, controlled };
pub const CandidatePairState = enum { waiting, in_progress, succeeded, failed, nominated };
pub const CandidatePair = struct { local: candidates.NatCandidate, remote: candidates.NatCandidate, priority: u64, state: CandidatePairState = .waiting };
pub const ConnectivitySignal = struct { pair: usize, role: ConnectivityRole, nominate: bool };
pub const ConnectivitySignaling = struct {
    context: *anyopaque,
    send_check_fn: *const fn (*anyopaque, ConnectivitySignal) bool,
    pub fn send_check(self: ConnectivitySignaling, signal: ConnectivitySignal) bool {
        return self.send_check_fn(self.context, signal);
    }
};
pub const DirectConnectivityError = std.mem.Allocator.Error || candidates.NatCandidateError || error{ InvalidConfiguration, PairCapacityExceeded, UnknownPair, InvalidState, RoleConflict, SignalingRejected, NoNominatedRoute };
pub const DirectConnectivityConfig = struct { maximum_pairs: usize, role: ConnectivityRole, tie_breaker: u64, signaling: ConnectivitySignaling };

pub const DirectConnectivity = struct {
    allocator: std.mem.Allocator,
    config: DirectConnectivityConfig,
    pairs: std.ArrayListUnmanaged(CandidatePair) = .empty,
    nominated: ?usize = null,
    pub fn init(allocator: std.mem.Allocator, config: DirectConnectivityConfig) DirectConnectivityError!DirectConnectivity {
        if (config.maximum_pairs == 0 or config.tie_breaker == 0) return error.InvalidConfiguration;
        return .{ .allocator = allocator, .config = config };
    }
    pub fn deinit(self: *DirectConnectivity) void {
        self.pairs.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn add_pair(self: *DirectConnectivity, local: candidates.NatCandidate, remote: candidates.NatCandidate, priority: u64, now_ns: u64) DirectConnectivityError!usize {
        try candidates.validate_nat_candidate(local, now_ns);
        try candidates.validate_nat_candidate(remote, now_ns);
        if (priority == 0) return error.InvalidConfiguration;
        if (self.pairs.items.len == self.config.maximum_pairs) return error.PairCapacityExceeded;
        try self.pairs.append(self.allocator, .{ .local = local, .remote = remote, .priority = priority });
        return self.pairs.items.len - 1;
    }
    pub fn check(self: *DirectConnectivity, pair: usize, should_nominate: bool) DirectConnectivityError!void {
        const value = self.pair_ptr(pair) orelse return error.UnknownPair;
        if (value.state != .waiting and value.state != .failed) return error.InvalidState;
        if (!self.config.signaling.send_check(.{ .pair = pair, .role = self.config.role, .nominate = should_nominate })) return error.SignalingRejected;
        value.state = .in_progress;
    }
    pub fn resolve_role_conflict(self: *DirectConnectivity, remote_role: ConnectivityRole, remote_tie_breaker: u64) DirectConnectivityError!void {
        if (remote_role != self.config.role) return;
        if (remote_tie_breaker == self.config.tie_breaker) return error.RoleConflict;
        if (remote_tie_breaker > self.config.tie_breaker) self.config.role = switch (self.config.role) {
            .controlling => .controlled,
            .controlled => .controlling,
        };
    }
    pub fn complete_check(self: *DirectConnectivity, pair: usize, success: bool) DirectConnectivityError!void {
        const value = self.pair_ptr(pair) orelse return error.UnknownPair;
        if (value.state != .in_progress) return error.InvalidState;
        value.state = if (success) .succeeded else .failed;
    }
    pub fn nominate(self: *DirectConnectivity, pair: usize) DirectConnectivityError!void {
        if (self.config.role != .controlling) return error.InvalidState;
        const value = self.pair_ptr(pair) orelse return error.UnknownPair;
        if (value.state != .succeeded) return error.InvalidState;
        if (self.nominated) |old| self.pairs.items[old].state = .succeeded;
        value.state = .nominated;
        self.nominated = pair;
    }
    pub fn direct_route(self: DirectConnectivity) DirectConnectivityError!CandidatePair {
        const pair = self.nominated orelse return error.NoNominatedRoute;
        return self.pairs.items[pair];
    }
    fn pair_ptr(self: *DirectConnectivity, index: usize) ?*CandidatePair {
        if (index >= self.pairs.items.len) return null;
        return &self.pairs.items[index];
    }
};

test "direct connectivity checks resolve roles signal nominate and choose a route" {
    const Fixture = struct {
        sent: usize = 0,
        fn send(context: *anyopaque, _: ConnectivitySignal) bool {
            @as(*@This(), @ptrCast(@alignCast(context))).sent += 1;
            return true;
        }
    };
    const candidate = candidates.NatCandidate{ .kind = .host, .transport = .udp, .address = .{ .ipv4 = .{ .octets = .{ 1, 1, 1, 1 }, .port = 1 } }, .priority = 1, .expires_at_ns = 100 };
    var fixture = Fixture{};
    var connectivity = try DirectConnectivity.init(std.testing.allocator, .{ .maximum_pairs = 1, .role = .controlling, .tie_breaker = 1, .signaling = .{ .context = &fixture, .send_check_fn = Fixture.send } });
    defer connectivity.deinit();
    const pair = try connectivity.add_pair(candidate, candidate, 1, 0);
    try connectivity.check(pair, true);
    try connectivity.complete_check(pair, true);
    try connectivity.nominate(pair);
    try std.testing.expectEqual(CandidatePairState.nominated, (try connectivity.direct_route()).state);
    try std.testing.expectEqual(@as(usize, 1), fixture.sent);
    try connectivity.resolve_role_conflict(.controlling, 2);
    try std.testing.expectEqual(ConnectivityRole.controlled, connectivity.config.role);
}

test "direct connectivity rejects bounded invalid and unsignaled routes" {
    const Fixture = struct {
        fn send(_: *anyopaque, _: ConnectivitySignal) bool {
            return false;
        }
    };
    const candidate = candidates.NatCandidate{ .kind = .host, .transport = .udp, .address = .{ .ipv4 = .{ .octets = .{ 1, 1, 1, 1 }, .port = 1 } }, .priority = 1, .expires_at_ns = 10 };
    var fixture = Fixture{};
    var connectivity = try DirectConnectivity.init(std.testing.allocator, .{ .maximum_pairs = 1, .role = .controlled, .tie_breaker = 1, .signaling = .{ .context = &fixture, .send_check_fn = Fixture.send } });
    defer connectivity.deinit();
    const pair = try connectivity.add_pair(candidate, candidate, 1, 0);
    try std.testing.expectError(error.SignalingRejected, connectivity.check(pair, false));
    try std.testing.expectError(error.NoNominatedRoute, connectivity.direct_route());
    try std.testing.expectError(error.RoleConflict, connectivity.resolve_role_conflict(.controlled, 1));
}
