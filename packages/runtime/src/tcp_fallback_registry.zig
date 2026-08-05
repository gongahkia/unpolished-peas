const std = @import("std");
const topology = @import("minna-san-topology");
const transport = @import("minna-san-transport");
const resource = @import("resource_handle.zig");

pub const max_tcp_fallback_transitions: usize = 16;
pub const UdpFallbackFailure = enum { send_failed, socket_error, socket_hangup, invalid_socket, path_mtu_exhausted };
pub const TcpFallbackRejection = enum { tcp_not_permitted, no_tcp_candidate, no_eligible_tcp, unsupported_capabilities };
pub const TcpFallbackTransitionKind = enum { udp_failed, downgraded_to_tcp, downgrade_rejected };
pub const TcpFallbackTransition = struct {
    sequence: u64,
    session: *resource.ResourceHandle,
    kind: TcpFallbackTransitionKind,
    failure: ?UdpFallbackFailure = null,
    candidate_id: ?u64 = null,
    rejection: ?TcpFallbackRejection = null,
};
pub const TcpFallbackEvent = struct {
    sequence: u64,
    session: *resource.ResourceHandle,
    failure: UdpFallbackFailure,
    candidate: topology.RouteCandidateSelection,
};
pub const TcpFallbackRegistryError = std.mem.Allocator.Error || resource.HandleError || topology.RouteCandidateSelectionError || error{ InvalidConfiguration, SessionCapacityExceeded, AlreadyRegistered, UnknownSession, AlreadyDowngraded, TcpFallbackDisallowed, NoTcpFallback, TransitionOutputTooSmall, SequenceExhausted };

const EntryState = enum { udp, tcp };
const Entry = struct {
    session: *resource.ResourceHandle,
    policy: topology.RouteCandidatePolicy,
    state: EntryState = .udp,
    next_sequence: u64 = 0,
    transitions: [max_tcp_fallback_transitions]TcpFallbackTransition = undefined,
    transition_start: usize = 0,
    transition_count: usize = 0,
};

pub const TcpFallbackRegistry = struct {
    allocator: std.mem.Allocator,
    capacity: usize,
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) TcpFallbackRegistryError!TcpFallbackRegistry {
        if (capacity == 0) return error.InvalidConfiguration;
        return .{ .allocator = allocator, .capacity = capacity };
    }

    pub fn deinit(self: *TcpFallbackRegistry) void {
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn register(self: *TcpFallbackRegistry, session: *resource.ResourceHandle, route_policy: topology.RouteCandidatePolicy) TcpFallbackRegistryError!void {
        try route_policy.validate();
        if (self.entries.items.len >= self.capacity) return error.SessionCapacityExceeded;
        for (self.entries.items) |entry| if (entry.session == session) return error.AlreadyRegistered;
        try self.entries.append(self.allocator, .{ .session = session, .policy = route_policy });
    }

    pub fn select(self: *TcpFallbackRegistry, session: *resource.ResourceHandle, failure: UdpFallbackFailure, candidates: []const topology.RouteCandidate) TcpFallbackRegistryError!TcpFallbackEvent {
        if (candidates.len > topology.max_route_candidates) return error.InvalidConfiguration;
        const entry = try self.lookup(session);
        if (entry.state != .udp) return error.AlreadyDowngraded;
        _ = try record(entry, .udp_failed, failure, null, null);
        const tcp_bit = topology.route_transport_bit(.tcp);
        if (entry.policy.allowed_transport_bits & tcp_bit == 0) {
            _ = try record(entry, .downgrade_rejected, failure, null, .tcp_not_permitted);
            return error.TcpFallbackDisallowed;
        }
        try validate_candidate_ids(candidates);
        var tcp_candidates: [topology.max_route_candidates]topology.RouteCandidate = undefined;
        var tcp_decisions: [topology.max_route_candidates]topology.RouteCandidateDecision = undefined;
        var tcp_count: usize = 0;
        for (candidates) |candidate| {
            if (candidate.transport != .tcp) continue;
            tcp_candidates[tcp_count] = candidate;
            tcp_count += 1;
        }
        if (tcp_count == 0) {
            _ = try record(entry, .downgrade_rejected, failure, null, .no_tcp_candidate);
            return error.NoTcpFallback;
        }
        const selector = try topology.RouteCandidateSelector.init(entry.policy);
        const selected = selector.select(tcp_candidates[0..tcp_count], tcp_decisions[0..tcp_count]) catch |err| switch (err) {
            error.NoRoute => {
                _ = try record(entry, .downgrade_rejected, failure, null, .no_eligible_tcp);
                return error.NoTcpFallback;
            },
            error.UnsupportedCapabilities => {
                _ = try record(entry, .downgrade_rejected, failure, null, .unsupported_capabilities);
                return err;
            },
            else => return err,
        };
        const transition = try record(entry, .downgraded_to_tcp, failure, selected.candidate.id, null);
        entry.state = .tcp;
        return .{ .sequence = transition.sequence, .session = session, .failure = failure, .candidate = selected };
    }

    pub fn listTransitions(self: *TcpFallbackRegistry, session: *resource.ResourceHandle, output: []TcpFallbackTransition) TcpFallbackRegistryError!usize {
        const entry = try self.lookup(session);
        if (output.len < entry.transition_count) return error.TransitionOutputTooSmall;
        for (0..entry.transition_count) |index| output[index] = entry.transitions[(entry.transition_start + index) % max_tcp_fallback_transitions];
        return entry.transition_count;
    }

    pub fn policy(self: *TcpFallbackRegistry, session: *resource.ResourceHandle) TcpFallbackRegistryError!topology.RouteCandidatePolicy {
        return (try self.lookup(session)).policy;
    }

    pub fn forget(self: *TcpFallbackRegistry, session: *resource.ResourceHandle) void {
        for (self.entries.items, 0..) |entry, index| {
            if (entry.session != session) continue;
            _ = self.entries.orderedRemove(index);
            return;
        }
    }

    fn lookup(self: *TcpFallbackRegistry, session: *resource.ResourceHandle) TcpFallbackRegistryError!*Entry {
        for (self.entries.items) |*entry| if (entry.session == session) return entry;
        return error.UnknownSession;
    }
};

fn record(entry: *Entry, kind: TcpFallbackTransitionKind, failure: UdpFallbackFailure, candidate_id: ?u64, rejection: ?TcpFallbackRejection) TcpFallbackRegistryError!TcpFallbackTransition {
    if (entry.next_sequence == std.math.maxInt(u64)) return error.SequenceExhausted;
    const transition = TcpFallbackTransition{ .sequence = entry.next_sequence, .session = entry.session, .kind = kind, .failure = failure, .candidate_id = candidate_id, .rejection = rejection };
    entry.next_sequence += 1;
    if (entry.transition_count < max_tcp_fallback_transitions) {
        entry.transitions[(entry.transition_start + entry.transition_count) % max_tcp_fallback_transitions] = transition;
        entry.transition_count += 1;
    } else {
        entry.transitions[entry.transition_start] = transition;
        entry.transition_start = (entry.transition_start + 1) % max_tcp_fallback_transitions;
    }
    return transition;
}

fn validate_candidate_ids(candidates: []const topology.RouteCandidate) TcpFallbackRegistryError!void {
    for (candidates, 0..) |candidate, index| {
        if (candidate.id == 0) continue;
        for (candidates[index + 1 ..]) |other| if (candidate.id == other.id) return error.InvalidConfiguration;
    }
}

test "TCP fallback selection records UDP failure then an ordered TCP downgrade" {
    var registry = try TcpFallbackRegistry.init(std.testing.allocator, 1);
    defer registry.deinit();
    const session: *resource.ResourceHandle = @ptrFromInt(1);
    const policy = topology.RouteCandidatePolicy{ .allowed_transport_bits = topology.route_transport_bit(.udp) | topology.route_transport_bit(.tcp) };
    try registry.register(session, policy);
    const candidates = [_]topology.RouteCandidate{
        .{ .id = 1, .transport = .udp, .endpoint = transport.Endpoint.from_ipv4(.{ .octets = .{ 127, 0, 0, 1 }, .port = 5000 }), .negotiated = true, .health = .healthy },
        .{ .id = 2, .transport = .tcp, .endpoint = transport.Endpoint.from_ipv4(.{ .octets = .{ 127, 0, 0, 1 }, .port = 5001 }), .negotiated = true, .health = .healthy },
    };
    const event = try registry.select(session, .send_failed, candidates[0..]);
    try std.testing.expectEqual(@as(u64, 1), event.sequence);
    try std.testing.expectEqual(@as(u64, 2), event.candidate.candidate.id);
    var transitions: [2]TcpFallbackTransition = undefined;
    try std.testing.expectEqual(@as(usize, 2), try registry.listTransitions(session, transitions[0..]));
    try std.testing.expectEqual(TcpFallbackTransitionKind.udp_failed, transitions[0].kind);
    try std.testing.expectEqual(@as(u64, 0), transitions[0].sequence);
    try std.testing.expectEqual(TcpFallbackTransitionKind.downgraded_to_tcp, transitions[1].kind);
    try std.testing.expectEqual(@as(u64, 1), transitions[1].sequence);
    try std.testing.expectEqual(UdpFallbackFailure.send_failed, transitions[1].failure.?);
}

test "TCP fallback records policy rejection without selecting TCP" {
    var registry = try TcpFallbackRegistry.init(std.testing.allocator, 1);
    defer registry.deinit();
    const session: *resource.ResourceHandle = @ptrFromInt(1);
    try registry.register(session, .{ .allowed_transport_bits = topology.route_transport_bit(.udp) });
    try std.testing.expectError(error.TcpFallbackDisallowed, registry.select(session, .socket_error, &.{}));
    var transitions: [2]TcpFallbackTransition = undefined;
    try std.testing.expectEqual(@as(usize, 2), try registry.listTransitions(session, transitions[0..]));
    try std.testing.expectEqual(TcpFallbackTransitionKind.downgrade_rejected, transitions[1].kind);
    try std.testing.expectEqual(TcpFallbackRejection.tcp_not_permitted, transitions[1].rejection.?);
}
