const std = @import("std");
const core = @import("minna-san-core");
const congestion = @import("congestion_controller.zig");

const nanoseconds_per_second: u64 = std.time.ns_per_s;

pub const max_paced_routes: usize = 64;
pub const PacingError = error{ InvalidConfiguration, RouteAlreadyRegistered, RouteCapacityExceeded, UnknownRoute, ClockRegression, TimeOverflow };

pub const PacingConfig = struct {
    bytes_per_second: usize,
    maximum_burst_bytes: usize,
    maximum_timer_ns: core.TimeNs,
};

pub const PacingReservation = struct {
    bytes: usize,
    wake_at_ns: core.TimeNs,
};

const RoutePacingState = struct {
    route: congestion.RouteId,
    tokens: usize,
    remainder_numerator: u64 = 0,
    last_updated_ns: core.TimeNs,
};

pub const PacketPacer = struct {
    config: PacingConfig,
    routes: [max_paced_routes]?RoutePacingState = .{null} ** max_paced_routes,

    pub fn init(config: PacingConfig) PacingError!PacketPacer {
        if (config.bytes_per_second == 0 or config.maximum_burst_bytes == 0 or config.maximum_timer_ns == 0) return error.InvalidConfiguration;
        return .{ .config = config };
    }

    pub fn register_route(self: *PacketPacer, route: congestion.RouteId, now_ns: core.TimeNs) PacingError!void {
        if (self.route_ptr(route) != null) return error.RouteAlreadyRegistered;
        for (&self.routes) |*slot| {
            if (slot.* == null) {
                slot.* = .{ .route = route, .tokens = self.config.maximum_burst_bytes, .last_updated_ns = now_ns };
                return;
            }
        }
        return error.RouteCapacityExceeded;
    }

    pub fn remove_route(self: *PacketPacer, route: congestion.RouteId) PacingError!void {
        for (&self.routes) |*slot| {
            const state = slot.* orelse continue;
            if (state.route == route) {
                slot.* = null;
                return;
            }
        }
        return error.UnknownRoute;
    }

    pub fn reserve(self: *PacketPacer, route: congestion.RouteId, congestion_budget: usize, requested_bytes: usize, now_ns: core.TimeNs) PacingError!PacingReservation {
        const state = self.route_ptr(route) orelse return error.UnknownRoute;
        try self.refill(state, now_ns);
        if (requested_bytes == 0) return .{ .bytes = 0, .wake_at_ns = now_ns };
        const available = @min(congestion_budget, requested_bytes);
        if (available == 0) return .{ .bytes = 0, .wake_at_ns = try self.deadline_after(now_ns, self.config.maximum_timer_ns) };
        const bytes = @min(state.tokens, available);
        if (bytes != 0) {
            state.tokens -= bytes;
            return .{ .bytes = bytes, .wake_at_ns = now_ns };
        }
        return .{ .bytes = 0, .wake_at_ns = try self.deadline_after(now_ns, @min(self.config.maximum_timer_ns, self.delay_until_one_byte(state))) };
    }

    fn route_ptr(self: *PacketPacer, route: congestion.RouteId) ?*RoutePacingState {
        for (&self.routes) |*slot| {
            const state = slot.* orelse continue;
            if (state.route == route) return &slot.*.?;
        }
        return null;
    }

    fn refill(self: *PacketPacer, state: *RoutePacingState, now_ns: core.TimeNs) PacingError!void {
        if (now_ns < state.last_updated_ns) return error.ClockRegression;
        const elapsed = now_ns - state.last_updated_ns;
        state.last_updated_ns = now_ns;
        if (elapsed == 0 or state.tokens == self.config.maximum_burst_bytes) return;
        const numerator = @as(u128, elapsed) * @as(u128, self.config.bytes_per_second) + state.remainder_numerator;
        const earned = numerator / nanoseconds_per_second;
        const remaining_capacity = @as(u128, self.config.maximum_burst_bytes - state.tokens);
        if (earned >= remaining_capacity) {
            state.tokens = self.config.maximum_burst_bytes;
            state.remainder_numerator = 0;
            return;
        }
        state.tokens += @intCast(earned);
        state.remainder_numerator = @intCast(numerator % nanoseconds_per_second);
    }

    fn delay_until_one_byte(self: PacketPacer, state: *const RoutePacingState) core.TimeNs {
        const required = @as(u128, nanoseconds_per_second) - state.remainder_numerator;
        const rate = @as(u128, self.config.bytes_per_second);
        const delay = (required + rate - 1) / rate;
        return @intCast(@min(@as(u128, self.config.maximum_timer_ns), delay));
    }

    fn deadline_after(_: *PacketPacer, now_ns: core.TimeNs, delay_ns: core.TimeNs) PacingError!core.TimeNs {
        return std.math.add(core.TimeNs, now_ns, delay_ns) catch return error.TimeOverflow;
    }
};

test "packet pacing converts congestion budget into bounded paced reservations" {
    var pacer = try PacketPacer.init(.{ .bytes_per_second = 100, .maximum_burst_bytes = 10, .maximum_timer_ns = 3_000_000 });
    try pacer.register_route(7, 0);
    var reservation = try pacer.reserve(7, 100, 100, 0);
    try std.testing.expectEqual(@as(usize, 10), reservation.bytes);
    try std.testing.expectEqual(@as(core.TimeNs, 0), reservation.wake_at_ns);
    reservation = try pacer.reserve(7, 4, 100, 0);
    try std.testing.expectEqual(@as(usize, 0), reservation.bytes);
    try std.testing.expectEqual(@as(core.TimeNs, 3_000_000), reservation.wake_at_ns);
    reservation = try pacer.reserve(7, 4, 100, 10_000_000);
    try std.testing.expectEqual(@as(usize, 1), reservation.bytes);
    try std.testing.expectEqual(@as(core.TimeNs, 10_000_000), reservation.wake_at_ns);
}

test "packet pacing handles congestion backpressure and monotonic failures" {
    var pacer = try PacketPacer.init(.{ .bytes_per_second = 1_000, .maximum_burst_bytes = 8, .maximum_timer_ns = 5 });
    try pacer.register_route(3, 10);
    var reservation = try pacer.reserve(3, 0, 4, 10);
    try std.testing.expectEqual(@as(usize, 0), reservation.bytes);
    try std.testing.expectEqual(@as(core.TimeNs, 15), reservation.wake_at_ns);
    reservation = try pacer.reserve(3, 2, 4, 10);
    try std.testing.expectEqual(@as(usize, 2), reservation.bytes);
    try std.testing.expectError(error.ClockRegression, pacer.reserve(3, 1, 1, 9));
    try std.testing.expectError(error.UnknownRoute, pacer.reserve(4, 1, 1, 10));
    try std.testing.expectError(error.TimeOverflow, pacer.reserve(3, 0, 1, std.math.maxInt(core.TimeNs)));
}

test "packet pacing validates configuration and route capacity" {
    try std.testing.expectError(error.InvalidConfiguration, PacketPacer.init(.{ .bytes_per_second = 0, .maximum_burst_bytes = 1, .maximum_timer_ns = 1 }));
    var pacer = try PacketPacer.init(.{ .bytes_per_second = 1, .maximum_burst_bytes = 1, .maximum_timer_ns = 1 });
    for (0..max_paced_routes) |route| try pacer.register_route(route, 0);
    try std.testing.expectError(error.RouteCapacityExceeded, pacer.register_route(max_paced_routes, 0));
    try pacer.remove_route(0);
    try std.testing.expectError(error.UnknownRoute, pacer.remove_route(0));
}
