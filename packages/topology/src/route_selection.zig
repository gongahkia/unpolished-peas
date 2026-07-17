const shards = @import("shard_directory.zig");

pub const RoutePolicy = enum { direct_first, relay_first, authoritative_first };
pub const RouteAvailability = struct { negotiated: bool, health: shards.ShardHealth };
pub const RouteCapabilities = struct {
    direct: RouteAvailability,
    relay: RouteAvailability,
    authoritative: RouteAvailability,
};
pub const RouteSelection = struct { kind: shards.ShardRouteKind, health: shards.ShardHealth };
pub const RouteSelectionError = error{ InvalidConfiguration, NoRoute };
pub const RouteSelectorConfig = struct {
    policy: RoutePolicy,
    allow_direct: bool = true,
    allow_relay: bool = true,
    allow_authoritative: bool = true,
    allow_degraded: bool = false,
};

pub const RouteSelector = struct {
    config: RouteSelectorConfig,

    pub fn init(config: RouteSelectorConfig) RouteSelectionError!RouteSelector {
        if (!config.allow_direct and !config.allow_relay and !config.allow_authoritative) return error.InvalidConfiguration;
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
        return error.NoRoute;
    }
    fn select_kind(self: RouteSelector, kind: shards.ShardRouteKind, capabilities: RouteCapabilities, health: shards.ShardHealth) ?RouteSelection {
        if (!self.allowed(kind)) return null;
        const availability = for_kind(capabilities, kind);
        if (!availability.negotiated or availability.health != health) return null;
        return .{ .kind = kind, .health = health };
    }
    fn allowed(self: RouteSelector, kind: shards.ShardRouteKind) bool {
        return switch (kind) {
            .direct => self.config.allow_direct,
            .relay => self.config.allow_relay,
            .authoritative => self.config.allow_authoritative,
        };
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
