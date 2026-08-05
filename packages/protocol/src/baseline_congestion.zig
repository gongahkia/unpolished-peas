const std = @import("std");
const congestion = @import("congestion_controller.zig");

pub const max_baseline_congestion_routes: usize = 64;
pub const BaselineCongestionError = error{ InvalidConfiguration, RouteAlreadyRegistered, RouteCapacityExceeded };

pub const BaselineCongestionConfig = struct {
    initial_window_bytes: usize = 12_000,
    minimum_window_bytes: usize = 2_400,
    maximum_window_bytes: usize = 1_048_576,
    maximum_segment_size: usize = 1_200,
};

pub const BaselineCongestionRouteState = struct {
    route: congestion.RouteId,
    congestion_window_bytes: usize,
    bytes_in_flight: usize = 0,
    smoothed_rtt_ns: ?u64 = null,
    rtt_variation_ns: ?u64 = null,
    acknowledged_for_growth: usize = 0,
    last_growth_ns: ?u64 = null,
};

pub const BaselineCongestionController = struct {
    config: BaselineCongestionConfig,
    routes: [max_baseline_congestion_routes]?BaselineCongestionRouteState = .{null} ** max_baseline_congestion_routes,

    pub fn init(config: BaselineCongestionConfig) BaselineCongestionError!BaselineCongestionController {
        if (config.maximum_segment_size == 0 or config.minimum_window_bytes == 0 or config.minimum_window_bytes > config.initial_window_bytes or config.initial_window_bytes > config.maximum_window_bytes or config.maximum_segment_size > config.maximum_window_bytes) return error.InvalidConfiguration;
        return .{ .config = config };
    }

    pub fn register_route(self: *BaselineCongestionController, route: congestion.RouteId) BaselineCongestionError!void {
        if (self.route_ptr(route) != null) return error.RouteAlreadyRegistered;
        for (&self.routes) |*slot| {
            if (slot.* == null) {
                slot.* = .{ .route = route, .congestion_window_bytes = self.config.initial_window_bytes };
                return;
            }
        }
        return error.RouteCapacityExceeded;
    }

    pub fn route_state(self: BaselineCongestionController, route: congestion.RouteId) ?BaselineCongestionRouteState {
        for (self.routes) |slot| {
            const state = slot orelse continue;
            if (state.route == route) return state;
        }
        return null;
    }

    pub fn controller(self: *BaselineCongestionController) congestion.CongestionController {
        return .{ .context = self, .send_budget_fn = send_budget_fn, .sent_fn = sent_fn, .feedback_fn = feedback_fn, .reset_fn = reset_fn };
    }

    fn send_budget_fn(context: *anyopaque, route: congestion.RouteId) usize {
        const self: *BaselineCongestionController = @ptrCast(@alignCast(context));
        const state = self.route_ptr(route) orelse return 0;
        return state.congestion_window_bytes -| state.bytes_in_flight;
    }

    fn sent_fn(context: *anyopaque, route: congestion.RouteId, bytes: usize, _: u64) void {
        const self: *BaselineCongestionController = @ptrCast(@alignCast(context));
        const state = self.route_ptr(route) orelse return;
        state.bytes_in_flight +|= bytes;
    }

    fn feedback_fn(context: *anyopaque, route: congestion.RouteId, feedback: congestion.CongestionFeedback, now_ns: u64) void {
        const self: *BaselineCongestionController = @ptrCast(@alignCast(context));
        const state = self.route_ptr(route) orelse return;
        self.update_rtt(state, feedback.rtt_ns);
        const acknowledged = @min(feedback.acknowledged_bytes, state.bytes_in_flight);
        state.bytes_in_flight -= acknowledged;
        const lost = @min(feedback.lost_bytes, state.bytes_in_flight);
        state.bytes_in_flight -= lost;
        if (feedback.lost_bytes != 0) {
            state.congestion_window_bytes = self.loss_window(state.bytes_in_flight +| lost);
            state.acknowledged_for_growth = 0;
            state.last_growth_ns = now_ns;
            return;
        }
        state.acknowledged_for_growth +|= acknowledged;
        if (state.acknowledged_for_growth < state.congestion_window_bytes or !self.may_grow(state, now_ns)) return;
        state.acknowledged_for_growth -= state.congestion_window_bytes;
        state.congestion_window_bytes = @min(self.config.maximum_window_bytes, state.congestion_window_bytes +| self.config.maximum_segment_size);
        state.last_growth_ns = now_ns;
    }

    fn reset_fn(context: *anyopaque, route: congestion.RouteId) void {
        const self: *BaselineCongestionController = @ptrCast(@alignCast(context));
        for (&self.routes) |*slot| {
            const state = slot.* orelse continue;
            if (state.route == route) {
                slot.* = null;
                return;
            }
        }
    }

    fn route_ptr(self: *BaselineCongestionController, route: congestion.RouteId) ?*BaselineCongestionRouteState {
        for (&self.routes) |*slot| {
            const state = slot.* orelse continue;
            if (state.route == route) return &slot.*.?;
        }
        return null;
    }

    fn update_rtt(_: *BaselineCongestionController, state: *BaselineCongestionRouteState, sample: ?u64) void {
        const measured = sample orelse return;
        if (measured == 0) return;
        const smoothed = state.smoothed_rtt_ns orelse {
            state.smoothed_rtt_ns = measured;
            state.rtt_variation_ns = measured / 2;
            return;
        };
        const variation = state.rtt_variation_ns orelse 0;
        const deviation = if (smoothed >= measured) smoothed - measured else measured - smoothed;
        state.rtt_variation_ns = weighted_average(variation, deviation, 3, 1, 4);
        state.smoothed_rtt_ns = weighted_average(smoothed, measured, 7, 1, 8);
    }

    fn may_grow(_: *BaselineCongestionController, state: *BaselineCongestionRouteState, now_ns: u64) bool {
        const rtt = state.smoothed_rtt_ns orelse return true;
        const previous = state.last_growth_ns orelse return true;
        return now_ns -| previous >= rtt;
    }

    fn loss_window(self: *BaselineCongestionController, flight_size: usize) usize {
        const two_segments = std.math.mul(usize, self.config.maximum_segment_size, 2) catch self.config.maximum_window_bytes;
        const floor = @min(self.config.maximum_window_bytes, @max(self.config.minimum_window_bytes, two_segments));
        return @min(self.config.maximum_window_bytes, @max(floor, flight_size / 2));
    }
};

fn weighted_average(previous: u64, sample: u64, previous_weight: u64, sample_weight: u64, divisor: u64) u64 {
    return @intCast((@as(u128, previous) * previous_weight + @as(u128, sample) * sample_weight) / divisor);
}

test "baseline congestion applies ACK-clocked growth and RTT smoothing" {
    var baseline = try BaselineCongestionController.init(.{
        .initial_window_bytes = 100,
        .minimum_window_bytes = 20,
        .maximum_window_bytes = 200,
        .maximum_segment_size = 10,
    });
    try baseline.register_route(7);
    const controller = baseline.controller();
    try std.testing.expectEqual(@as(usize, 100), controller.send_budget(7));
    controller.on_sent(7, 100, 0);
    try std.testing.expectEqual(@as(usize, 0), controller.send_budget(7));
    controller.on_feedback(7, .{ .acknowledged_bytes = 100, .rtt_ns = 100 }, 100);
    var state = baseline.route_state(7).?;
    try std.testing.expectEqual(@as(usize, 110), state.congestion_window_bytes);
    try std.testing.expectEqual(@as(usize, 0), state.bytes_in_flight);
    try std.testing.expectEqual(@as(?u64, 100), state.smoothed_rtt_ns);
    try std.testing.expectEqual(@as(?u64, 50), state.rtt_variation_ns);
    controller.on_sent(7, 110, 101);
    controller.on_feedback(7, .{ .acknowledged_bytes = 110, .rtt_ns = 140 }, 150);
    state = baseline.route_state(7).?;
    try std.testing.expectEqual(@as(usize, 110), state.congestion_window_bytes);
    try std.testing.expectEqual(@as(?u64, 105), state.smoothed_rtt_ns);
    try std.testing.expectEqual(@as(?u64, 47), state.rtt_variation_ns);
    controller.on_feedback(7, .{}, 250);
    try std.testing.expectEqual(@as(usize, 120), baseline.route_state(7).?.congestion_window_bytes);
}

test "baseline congestion halves the flight window on loss and respects route lifecycle" {
    var baseline = try BaselineCongestionController.init(.{
        .initial_window_bytes = 100,
        .minimum_window_bytes = 20,
        .maximum_window_bytes = 200,
        .maximum_segment_size = 10,
    });
    try baseline.register_route(9);
    const controller = baseline.controller();
    controller.on_sent(9, 80, 0);
    controller.on_feedback(9, .{ .lost_bytes = 20 }, 1);
    const state = baseline.route_state(9).?;
    try std.testing.expectEqual(@as(usize, 40), state.congestion_window_bytes);
    try std.testing.expectEqual(@as(usize, 60), state.bytes_in_flight);
    try std.testing.expectEqual(@as(usize, 0), controller.send_budget(9));
    controller.reset(9);
    try std.testing.expect(baseline.route_state(9) == null);
    try std.testing.expectEqual(@as(usize, 0), controller.send_budget(9));
}

test "baseline congestion validates configuration and bounded routes" {
    try std.testing.expectError(error.InvalidConfiguration, BaselineCongestionController.init(.{ .maximum_segment_size = 0 }));
    var baseline = try BaselineCongestionController.init(.{});
    try baseline.register_route(1);
    try std.testing.expectError(error.RouteAlreadyRegistered, baseline.register_route(1));
    for (2..max_baseline_congestion_routes + 1) |route| try baseline.register_route(route);
    try std.testing.expectError(error.RouteCapacityExceeded, baseline.register_route(max_baseline_congestion_routes + 1));
}
