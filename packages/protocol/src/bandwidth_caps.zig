const std = @import("std");
const core = @import("minna-san-core");
const congestion = @import("congestion_controller.zig");

const nanoseconds_per_second: u64 = std.time.ns_per_s;

pub const max_bandwidth_routes: usize = 64;
pub const BandwidthCapError = error{ InvalidConfiguration, RouteAlreadyRegistered, RouteCapacityExceeded, UnknownRoute, ClockRegression };

pub const BandwidthDirection = enum {
    ingress,
    egress,
};

pub const TrafficClass = enum {
    control,
    payload,
};

pub const BandwidthDirectionConfig = struct {
    bytes_per_second: usize,
    maximum_burst_bytes: usize,
    control_reserve_bytes: usize,
};

pub const BandwidthCapConfig = struct {
    ingress: BandwidthDirectionConfig,
    egress: BandwidthDirectionConfig,
};

const DirectionState = struct {
    tokens: usize,
    remainder_numerator: u64 = 0,
    last_updated_ns: core.TimeNs,
};

const RouteBandwidthState = struct {
    route: congestion.RouteId,
    config: BandwidthCapConfig,
    ingress: DirectionState,
    egress: DirectionState,
};

pub const BandwidthLimiter = struct {
    routes: [max_bandwidth_routes]?RouteBandwidthState = .{null} ** max_bandwidth_routes,

    pub fn register_route(self: *BandwidthLimiter, route: congestion.RouteId, config: BandwidthCapConfig, now_ns: core.TimeNs) BandwidthCapError!void {
        try validate_config(config);
        if (self.route_ptr(route) != null) return error.RouteAlreadyRegistered;
        for (&self.routes) |*slot| {
            if (slot.* == null) {
                slot.* = .{
                    .route = route,
                    .config = config,
                    .ingress = .{ .tokens = config.ingress.maximum_burst_bytes, .last_updated_ns = now_ns },
                    .egress = .{ .tokens = config.egress.maximum_burst_bytes, .last_updated_ns = now_ns },
                };
                return;
            }
        }
        return error.RouteCapacityExceeded;
    }

    pub fn remove_route(self: *BandwidthLimiter, route: congestion.RouteId) BandwidthCapError!void {
        for (&self.routes) |*slot| {
            const state = slot.* orelse continue;
            if (state.route == route) {
                slot.* = null;
                return;
            }
        }
        return error.UnknownRoute;
    }

    pub fn admit(self: *BandwidthLimiter, route: congestion.RouteId, direction: BandwidthDirection, class: TrafficClass, requested_bytes: usize, now_ns: core.TimeNs) BandwidthCapError!usize {
        const route_state = self.route_ptr(route) orelse return error.UnknownRoute;
        const direction_config = switch (direction) {
            .ingress => route_state.config.ingress,
            .egress => route_state.config.egress,
        };
        const state = switch (direction) {
            .ingress => &route_state.ingress,
            .egress => &route_state.egress,
        };
        try refill(state, direction_config, now_ns);
        const available = switch (class) {
            .control => state.tokens,
            .payload => state.tokens -| direction_config.control_reserve_bytes,
        };
        const admitted = @min(requested_bytes, available);
        state.tokens -= admitted;
        return admitted;
    }

    fn route_ptr(self: *BandwidthLimiter, route: congestion.RouteId) ?*RouteBandwidthState {
        for (&self.routes) |*slot| {
            const state = slot.* orelse continue;
            if (state.route == route) return &slot.*.?;
        }
        return null;
    }
};

fn validate_config(config: BandwidthCapConfig) BandwidthCapError!void {
    inline for (.{ config.ingress, config.egress }) |direction| {
        if (direction.bytes_per_second == 0 or direction.maximum_burst_bytes == 0 or direction.control_reserve_bytes > direction.maximum_burst_bytes) return error.InvalidConfiguration;
    }
}

fn refill(state: *DirectionState, config: BandwidthDirectionConfig, now_ns: core.TimeNs) BandwidthCapError!void {
    if (now_ns < state.last_updated_ns) return error.ClockRegression;
    const elapsed = now_ns - state.last_updated_ns;
    state.last_updated_ns = now_ns;
    if (elapsed == 0 or state.tokens == config.maximum_burst_bytes) return;
    const numerator = @as(u128, elapsed) * @as(u128, config.bytes_per_second) + state.remainder_numerator;
    const earned = numerator / nanoseconds_per_second;
    const remaining_capacity = @as(u128, config.maximum_burst_bytes - state.tokens);
    if (earned >= remaining_capacity) {
        state.tokens = config.maximum_burst_bytes;
        state.remainder_numerator = 0;
        return;
    }
    state.tokens += @intCast(earned);
    state.remainder_numerator = @intCast(numerator % nanoseconds_per_second);
}

test "bandwidth caps preserve per-direction control traffic reserves" {
    const config = BandwidthCapConfig{
        .ingress = .{ .bytes_per_second = 100, .maximum_burst_bytes = 10, .control_reserve_bytes = 3 },
        .egress = .{ .bytes_per_second = 50, .maximum_burst_bytes = 8, .control_reserve_bytes = 2 },
    };
    var limiter = BandwidthLimiter{};
    try limiter.register_route(7, config, 0);
    try std.testing.expectEqual(@as(usize, 7), try limiter.admit(7, .ingress, .payload, 100, 0));
    try std.testing.expectEqual(@as(usize, 3), try limiter.admit(7, .ingress, .control, 100, 0));
    try std.testing.expectEqual(@as(usize, 4), try limiter.admit(7, .egress, .control, 4, 0));
    try std.testing.expectEqual(@as(usize, 2), try limiter.admit(7, .egress, .payload, 100, 0));
    try std.testing.expectEqual(@as(usize, 0), try limiter.admit(7, .ingress, .payload, 100, 10_000_000));
    try std.testing.expectEqual(@as(usize, 1), try limiter.admit(7, .ingress, .control, 100, 10_000_000));
}

test "bandwidth caps reject invalid lifecycle and time inputs" {
    const config = BandwidthCapConfig{
        .ingress = .{ .bytes_per_second = 1, .maximum_burst_bytes = 2, .control_reserve_bytes = 1 },
        .egress = .{ .bytes_per_second = 1, .maximum_burst_bytes = 2, .control_reserve_bytes = 1 },
    };
    var limiter = BandwidthLimiter{};
    try limiter.register_route(1, config, 10);
    try std.testing.expectError(error.RouteAlreadyRegistered, limiter.register_route(1, config, 10));
    try std.testing.expectError(error.UnknownRoute, limiter.admit(2, .ingress, .control, 1, 10));
    try std.testing.expectError(error.ClockRegression, limiter.admit(1, .ingress, .control, 1, 9));
    try limiter.remove_route(1);
    try std.testing.expectError(error.UnknownRoute, limiter.remove_route(1));
    const invalid = BandwidthCapConfig{
        .ingress = .{ .bytes_per_second = 0, .maximum_burst_bytes = 1, .control_reserve_bytes = 0 },
        .egress = .{ .bytes_per_second = 1, .maximum_burst_bytes = 1, .control_reserve_bytes = 2 },
    };
    try std.testing.expectError(error.InvalidConfiguration, limiter.register_route(2, invalid, 0));
}

test "bandwidth caps enforce bounded route capacity" {
    const config = BandwidthCapConfig{
        .ingress = .{ .bytes_per_second = 1, .maximum_burst_bytes = 1, .control_reserve_bytes = 0 },
        .egress = .{ .bytes_per_second = 1, .maximum_burst_bytes = 1, .control_reserve_bytes = 0 },
    };
    var limiter = BandwidthLimiter{};
    for (0..max_bandwidth_routes) |route| try limiter.register_route(route, config, 0);
    try std.testing.expectError(error.RouteCapacityExceeded, limiter.register_route(max_bandwidth_routes, config, 0));
}
