const core = @import("minna-san-core");
const transport = @import("minna-san-transport");
const shards = @import("shard_directory.zig");

pub const max_route_candidates: usize = 8;
pub const route_transport_count: usize = 5;
pub const RouteTransport = enum(u8) { udp, tcp, relay, http, quic };
pub const all_route_transport_bits: u8 = (@as(u8, 1) << route_transport_count) - 1;
pub const RouteCandidateRejection = enum { policy_disabled, not_negotiated, unavailable, degraded_disallowed, invalid_candidate, invalid_capabilities, unsupported_capabilities, lower_priority };
pub const RouteCandidate = struct {
    id: u64,
    transport: RouteTransport,
    endpoint: transport.Endpoint,
    negotiated: bool,
    health: shards.ShardHealth,
    capabilities: core.ProviderCapabilityDescriptor = .{},
    priority: u16 = 0,
};
pub const RouteCandidateDecision = union(enum) {
    selected: struct { candidate_id: u64, policy_rank: u8 },
    rejected: struct { candidate_id: u64, reason: RouteCandidateRejection },
};
pub const RouteCandidateSelection = struct { candidate: RouteCandidate, policy_rank: u8 };
pub const RouteCandidateSelectionError = error{ InvalidConfiguration, OutputTooSmall, UnsupportedCapabilities, NoRoute };
pub const RouteCandidatePolicy = struct {
    transport_order: [route_transport_count]RouteTransport = .{ .udp, .tcp, .relay, .http, .quic },
    allowed_transport_bits: u8 = all_route_transport_bits,
    allow_degraded: bool = false,
    required_capabilities: core.ProviderCapabilityRequirement = .{},

    pub fn validate(self: RouteCandidatePolicy) RouteCandidateSelectionError!void {
        if (self.allowed_transport_bits == 0 or self.allowed_transport_bits & ~all_route_transport_bits != 0) return error.InvalidConfiguration;
        var seen: u8 = 0;
        for (self.transport_order) |item| {
            const bit = route_transport_bit(item);
            if (seen & bit != 0) return error.InvalidConfiguration;
            seen |= bit;
        }
        if (seen != all_route_transport_bits) return error.InvalidConfiguration;
        self.required_capabilities.validate() catch return error.InvalidConfiguration;
    }

    fn rank(self: RouteCandidatePolicy, item: RouteTransport) ?u8 {
        if (self.allowed_transport_bits & route_transport_bit(item) == 0) return null;
        for (self.transport_order, 0..) |ordered, index| if (ordered == item) return @intCast(index);
        return null;
    }
};
pub const RouteCandidateSelector = struct {
    policy: RouteCandidatePolicy,

    pub fn init(policy: RouteCandidatePolicy) RouteCandidateSelectionError!RouteCandidateSelector {
        try policy.validate();
        return .{ .policy = policy };
    }

    pub fn select(self: RouteCandidateSelector, candidates: []const RouteCandidate, decisions: []RouteCandidateDecision) RouteCandidateSelectionError!RouteCandidateSelection {
        if (candidates.len > max_route_candidates) return error.InvalidConfiguration;
        if (decisions.len < candidates.len) return error.OutputTooSmall;
        for (candidates, 0..) |candidate, index| {
            if (candidate.id == 0) continue;
            for (candidates[index + 1 ..]) |other| if (candidate.id == other.id) return error.InvalidConfiguration;
        }
        var selected: ?struct { index: usize, value: RouteCandidateSelection } = null;
        var unsupported = false;
        for (candidates, 0..) |candidate, index| {
            const rank = self.policy.rank(candidate.transport) orelse {
                decisions[index] = .{ .rejected = .{ .candidate_id = candidate.id, .reason = .policy_disabled } };
                continue;
            };
            const rejection = candidate_rejection(self.policy, candidate, &unsupported);
            if (rejection) |reason| {
                decisions[index] = .{ .rejected = .{ .candidate_id = candidate.id, .reason = reason } };
                continue;
            }
            decisions[index] = .{ .rejected = .{ .candidate_id = candidate.id, .reason = .lower_priority } };
            const value = RouteCandidateSelection{ .candidate = candidate, .policy_rank = rank };
            if (selected == null or selection_precedes(value, selected.?.value)) selected = .{ .index = index, .value = value };
        }
        const result = selected orelse return if (unsupported) error.UnsupportedCapabilities else error.NoRoute;
        decisions[result.index] = .{ .selected = .{ .candidate_id = result.value.candidate.id, .policy_rank = result.value.policy_rank } };
        return result.value;
    }
};

pub fn route_transport_bit(item: RouteTransport) u8 {
    return @as(u8, 1) << @as(u3, @intCast(@intFromEnum(item)));
}

fn candidate_rejection(policy: RouteCandidatePolicy, candidate: RouteCandidate, unsupported: *bool) ?RouteCandidateRejection {
    if (candidate.id == 0 or !candidate.endpoint.is_valid()) return .invalid_candidate;
    if (!candidate.negotiated) return .not_negotiated;
    if (candidate.health == .unavailable) return .unavailable;
    if (candidate.health == .degraded and !policy.allow_degraded) return .degraded_disallowed;
    candidate.capabilities.validate() catch {
        unsupported.* = true;
        return .invalid_capabilities;
    };
    if (!candidate.capabilities.supports(policy.required_capabilities)) {
        unsupported.* = true;
        return .unsupported_capabilities;
    }
    return null;
}

fn selection_precedes(left: RouteCandidateSelection, right: RouteCandidateSelection) bool {
    if (left.policy_rank != right.policy_rank) return left.policy_rank < right.policy_rank;
    if (left.candidate.priority != right.candidate.priority) return left.candidate.priority > right.candidate.priority;
    return left.candidate.id < right.candidate.id;
}

pub const RoutePolicy = enum { direct_first, relay_first, authoritative_first };
pub const RouteAvailability = struct {
    negotiated: bool,
    health: shards.ShardHealth,
    capabilities: core.ProviderCapabilityDescriptor = .{},
};
pub const RouteCapabilities = struct {
    direct: RouteAvailability,
    relay: RouteAvailability,
    authoritative: RouteAvailability,
};
pub const RouteSelection = struct { kind: shards.ShardRouteKind, health: shards.ShardHealth };
pub const RouteSelectionError = error{ InvalidConfiguration, UnsupportedCapabilities, NoRoute };
pub const RouteSelectorConfig = struct {
    policy: RoutePolicy,
    allow_direct: bool = true,
    allow_relay: bool = true,
    allow_authoritative: bool = true,
    allow_degraded: bool = false,
    required_capabilities: core.ProviderCapabilityRequirement = .{},
};

pub const RouteSelector = struct {
    config: RouteSelectorConfig,

    pub fn init(config: RouteSelectorConfig) RouteSelectionError!RouteSelector {
        if (!config.allow_direct and !config.allow_relay and !config.allow_authoritative) return error.InvalidConfiguration;
        config.required_capabilities.validate() catch return error.InvalidConfiguration;
        return .{ .config = config };
    }
    pub fn select(self: RouteSelector, capabilities: RouteCapabilities) RouteSelectionError!RouteSelection {
        const order = switch (self.config.policy) {
            .direct_first => [_]shards.ShardRouteKind{ .direct, .relay, .authoritative },
            .relay_first => [_]shards.ShardRouteKind{ .relay, .direct, .authoritative },
            .authoritative_first => [_]shards.ShardRouteKind{ .authoritative, .direct, .relay },
        };
        for (order) |kind| if (self.select_kind(kind, capabilities, .healthy)) |selected| return selected;
        if (self.config.allow_degraded) for (order) |kind| if (self.select_kind(kind, capabilities, .degraded)) |selected| return selected;
        if (self.hasUnsupportedViableRoute(capabilities)) return error.UnsupportedCapabilities;
        return error.NoRoute;
    }
    fn select_kind(self: RouteSelector, kind: shards.ShardRouteKind, capabilities: RouteCapabilities, health: shards.ShardHealth) ?RouteSelection {
        if (!self.allowed(kind)) return null;
        const availability = for_kind(capabilities, kind);
        availability.capabilities.validate() catch return null;
        if (!availability.negotiated or availability.health != health or !availability.capabilities.supports(self.config.required_capabilities)) return null;
        return .{ .kind = kind, .health = health };
    }
    fn allowed(self: RouteSelector, kind: shards.ShardRouteKind) bool {
        return switch (kind) {
            .direct => self.config.allow_direct,
            .relay => self.config.allow_relay,
            .authoritative => self.config.allow_authoritative,
        };
    }

    fn hasUnsupportedViableRoute(self: RouteSelector, capabilities: RouteCapabilities) bool {
        for ([_]shards.ShardRouteKind{ .direct, .relay, .authoritative }) |kind| {
            if (!self.allowed(kind)) continue;
            const availability = for_kind(capabilities, kind);
            const allowed_health = availability.health == .healthy or (self.config.allow_degraded and availability.health == .degraded);
            if (availability.negotiated and allowed_health) {
                availability.capabilities.validate() catch return true;
                if (!availability.capabilities.supports(self.config.required_capabilities)) return true;
            }
        }
        return false;
    }
};

pub fn for_kind(capabilities: RouteCapabilities, kind: shards.ShardRouteKind) RouteAvailability {
    return switch (kind) {
        .direct => capabilities.direct,
        .relay => capabilities.relay,
        .authoritative => capabilities.authoritative,
    };
}

test "route selector honors negotiation health policy and user enabled routes" {
    const capabilities = RouteCapabilities{
        .direct = .{ .negotiated = true, .health = .healthy },
        .relay = .{ .negotiated = true, .health = .healthy },
        .authoritative = .{ .negotiated = true, .health = .healthy },
    };
    const direct = try RouteSelector.init(.{ .policy = .direct_first });
    try @import("std").testing.expectEqual(RouteSelection{ .kind = .direct, .health = .healthy }, try direct.select(capabilities));
    const relay = try RouteSelector.init(.{ .policy = .relay_first });
    try @import("std").testing.expectEqual(RouteSelection{ .kind = .relay, .health = .healthy }, try relay.select(capabilities));
    const constrained = try RouteSelector.init(.{ .policy = .relay_first, .allow_relay = false });
    try @import("std").testing.expectEqual(RouteSelection{ .kind = .direct, .health = .healthy }, try constrained.select(capabilities));
}

test "route selector falls back only to configured viable routes" {
    const selector = try RouteSelector.init(.{ .policy = .direct_first, .allow_degraded = true });
    const degraded = RouteCapabilities{
        .direct = .{ .negotiated = true, .health = .unavailable },
        .relay = .{ .negotiated = true, .health = .degraded },
        .authoritative = .{ .negotiated = false, .health = .healthy },
    };
    try @import("std").testing.expectEqual(RouteSelection{ .kind = .relay, .health = .degraded }, try selector.select(degraded));
    const direct_only = try RouteSelector.init(.{ .policy = .direct_first, .allow_relay = false, .allow_authoritative = false });
    try @import("std").testing.expectError(error.NoRoute, direct_only.select(degraded));
    try @import("std").testing.expectError(error.InvalidConfiguration, RouteSelector.init(.{ .policy = .direct_first, .allow_direct = false, .allow_relay = false, .allow_authoritative = false }));
}

test "route selection rejects unsupported provider capabilities before dialing" {
    const required = core.ProviderCapabilityRequirement{
        .transport_bits = core.transport_capability_bit(.quic),
        .security_bits = core.security_capability_bit(.tls),
        .delivery_bits = core.delivery_capability_bit(.datagrams),
        .protocol_bits = core.protocol_capability_bit(.http3),
    };
    const selector = try RouteSelector.init(.{ .policy = .direct_first, .allow_relay = false, .allow_authoritative = false, .required_capabilities = required });
    const unavailable = RouteCapabilities{
        .direct = .{ .negotiated = true, .health = .healthy, .capabilities = .{ .transport_bits = core.transport_capability_bit(.quic), .security_bits = core.security_capability_bit(.tls), .delivery_bits = core.delivery_capability_bit(.streams), .protocol_bits = core.protocol_capability_bit(.http3) } },
        .relay = .{ .negotiated = false, .health = .unavailable },
        .authoritative = .{ .negotiated = false, .health = .unavailable },
    };
    try @import("std").testing.expectError(error.UnsupportedCapabilities, selector.select(unavailable));
    const supported = unavailable;
    var selected = supported;
    selected.direct.capabilities.delivery_bits |= core.delivery_capability_bit(.datagrams);
    try @import("std").testing.expectEqual(RouteSelection{ .kind = .direct, .health = .healthy }, selector.select(selected));
    selected.direct.capabilities.version = core.provider_capability_descriptor_version + 1;
    try @import("std").testing.expectError(error.UnsupportedCapabilities, selector.select(selected));
}

test "route candidate selectors rank identical fake network inputs deterministically" {
    const candidates = [_]RouteCandidate{
        .{ .id = 1, .transport = .udp, .endpoint = transport.Endpoint.from_ipv4(.{ .octets = .{ 127, 0, 0, 1 }, .port = 5000 }), .negotiated = true, .health = .healthy, .priority = 9 },
        .{ .id = 2, .transport = .tcp, .endpoint = transport.Endpoint.from_ipv6(.{ .octets = .{0} ** 15 ++ .{1}, .port = 5001, .scope_id = 0 }), .negotiated = true, .health = .healthy, .priority = 7 },
        .{ .id = 3, .transport = .relay, .endpoint = try transport.Endpoint.from_provider("turn", 3478), .negotiated = true, .health = .healthy },
        .{ .id = 4, .transport = .http, .endpoint = try transport.Endpoint.from_hostname("api.example.test", 443), .negotiated = true, .health = .healthy },
        .{ .id = 5, .transport = .quic, .endpoint = transport.Endpoint.from_ipv6(.{ .octets = .{ 0x20, 0x01, 0x0d, 0xb8 } ++ [_]u8{0} ** 11 ++ .{1}, .port = 443, .scope_id = 0 }), .negotiated = true, .health = .healthy, .priority = 1 },
    };
    const selector = try RouteCandidateSelector.init(.{ .transport_order = .{ .quic, .udp, .tcp, .relay, .http } });
    var first: [candidates.len]RouteCandidateDecision = undefined;
    var second: [candidates.len]RouteCandidateDecision = undefined;
    const first_selection = try selector.select(candidates[0..], first[0..]);
    const second_selection = try selector.select(candidates[0..], second[0..]);
    try @import("std").testing.expectEqual(@as(u64, 5), first_selection.candidate.id);
    try @import("std").testing.expectEqual(first_selection, second_selection);
    try @import("std").testing.expectEqual(first, second);
}

test "route candidate selectors expose explicit rejection reasons" {
    const selector = try RouteCandidateSelector.init(.{ .allowed_transport_bits = route_transport_bit(.udp), .required_capabilities = .{ .transport_bits = core.transport_capability_bit(.udp) } });
    const candidates = [_]RouteCandidate{
        .{ .id = 1, .transport = .tcp, .endpoint = transport.Endpoint.from_ipv4(.{ .octets = .{ 127, 0, 0, 1 }, .port = 1 }), .negotiated = true, .health = .healthy },
        .{ .id = 2, .transport = .udp, .endpoint = transport.Endpoint.from_ipv4(.{ .octets = .{ 127, 0, 0, 1 }, .port = 2 }), .negotiated = false, .health = .healthy },
        .{ .id = 3, .transport = .udp, .endpoint = transport.Endpoint.from_ipv4(.{ .octets = .{ 127, 0, 0, 1 }, .port = 3 }), .negotiated = true, .health = .healthy, .capabilities = .{ .transport_bits = core.transport_capability_bit(.tcp) } },
    };
    var decisions: [candidates.len]RouteCandidateDecision = undefined;
    var tiny: [0]RouteCandidateDecision = .{};
    try @import("std").testing.expectError(error.OutputTooSmall, selector.select(candidates[0..], tiny[0..]));
    try @import("std").testing.expectError(error.UnsupportedCapabilities, selector.select(candidates[0..], decisions[0..]));
    try @import("std").testing.expectEqual(RouteCandidateDecision{ .rejected = .{ .candidate_id = 1, .reason = .policy_disabled } }, decisions[0]);
    try @import("std").testing.expectEqual(RouteCandidateDecision{ .rejected = .{ .candidate_id = 2, .reason = .not_negotiated } }, decisions[1]);
    try @import("std").testing.expectEqual(RouteCandidateDecision{ .rejected = .{ .candidate_id = 3, .reason = .unsupported_capabilities } }, decisions[2]);
}
