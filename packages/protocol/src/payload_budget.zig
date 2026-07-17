const std = @import("std");
const capability = @import("capability_negotiation.zig");
const congestion = @import("congestion_controller.zig");
const packet = @import("packet_envelope.zig");

pub const max_payload_budget_routes: usize = 64;
pub const max_route_mtu_bytes: usize = packet.max_packet_payload_bytes;
pub const PayloadBudgetError = error{ InvalidConfiguration, InvalidOffer, RouteAlreadyRegistered, RouteCapacityExceeded, UnknownRoute };

pub const MtuBudgetConfig = struct {
    transport: capability.TransportCapability,
    mtu_bytes: usize,
    transport_overhead_bytes: usize,
    protocol_overhead_bytes: usize = packet.packet_header_bytes,
};

pub const MtuBudgetOffer = struct {
    mtu_bytes: usize,
    transport_overhead_bytes: usize,
    protocol_overhead_bytes: usize,
};

pub const EffectivePayloadBudget = struct {
    route: congestion.RouteId,
    transport: capability.TransportCapability,
    effective_mtu_bytes: usize,
    payload_bytes: usize,
};

const RouteBudgetState = struct {
    route: congestion.RouteId,
    config: MtuBudgetConfig,
    effective: ?EffectivePayloadBudget = null,
};

pub const PayloadBudgetManager = struct {
    routes: [max_payload_budget_routes]?RouteBudgetState = .{null} ** max_payload_budget_routes,

    pub fn register_route(self: *PayloadBudgetManager, route: congestion.RouteId, config: MtuBudgetConfig) PayloadBudgetError!void {
        try validate_config(config);
        if (self.route_ptr(route) != null) return error.RouteAlreadyRegistered;
        for (&self.routes) |*slot| {
            if (slot.* == null) {
                slot.* = .{ .route = route, .config = config };
                return;
            }
        }
        return error.RouteCapacityExceeded;
    }

    pub fn remove_route(self: *PayloadBudgetManager, route: congestion.RouteId) PayloadBudgetError!void {
        for (&self.routes) |*slot| {
            const state = slot.* orelse continue;
            if (state.route == route) {
                slot.* = null;
                return;
            }
        }
        return error.UnknownRoute;
    }

    pub fn offer(self: *PayloadBudgetManager, route: congestion.RouteId) PayloadBudgetError!MtuBudgetOffer {
        const state = self.route_ptr(route) orelse return error.UnknownRoute;
        return .{
            .mtu_bytes = state.config.mtu_bytes,
            .transport_overhead_bytes = state.config.transport_overhead_bytes,
            .protocol_overhead_bytes = state.config.protocol_overhead_bytes,
        };
    }

    pub fn negotiate(self: *PayloadBudgetManager, route: congestion.RouteId, remote: MtuBudgetOffer) PayloadBudgetError!EffectivePayloadBudget {
        try validate_offer(remote);
        const state = self.route_ptr(route) orelse return error.UnknownRoute;
        const effective = EffectivePayloadBudget{
            .route = route,
            .transport = state.config.transport,
            .effective_mtu_bytes = @min(state.config.mtu_bytes, remote.mtu_bytes),
            .payload_bytes = @min(payload_capacity(state.config.mtu_bytes, state.config.transport_overhead_bytes, state.config.protocol_overhead_bytes), payload_capacity(remote.mtu_bytes, remote.transport_overhead_bytes, remote.protocol_overhead_bytes)),
        };
        state.effective = effective;
        return effective;
    }

    pub fn effective_payload_budget(self: *PayloadBudgetManager, route: congestion.RouteId) PayloadBudgetError!?EffectivePayloadBudget {
        return (self.route_ptr(route) orelse return error.UnknownRoute).effective;
    }

    fn route_ptr(self: *PayloadBudgetManager, route: congestion.RouteId) ?*RouteBudgetState {
        for (&self.routes) |*slot| {
            const state = slot.* orelse continue;
            if (state.route == route) return &slot.*.?;
        }
        return null;
    }
};

fn validate_config(config: MtuBudgetConfig) PayloadBudgetError!void {
    if (config.mtu_bytes > max_route_mtu_bytes or config.protocol_overhead_bytes < packet.packet_header_bytes) return error.InvalidConfiguration;
    try validate_budget(config.mtu_bytes, config.transport_overhead_bytes, config.protocol_overhead_bytes, error.InvalidConfiguration);
}

fn validate_offer(offer: MtuBudgetOffer) PayloadBudgetError!void {
    if (offer.mtu_bytes > max_route_mtu_bytes or offer.protocol_overhead_bytes < packet.packet_header_bytes) return error.InvalidOffer;
    try validate_budget(offer.mtu_bytes, offer.transport_overhead_bytes, offer.protocol_overhead_bytes, error.InvalidOffer);
}

fn validate_budget(mtu_bytes: usize, transport_overhead_bytes: usize, protocol_overhead_bytes: usize, comptime failure: PayloadBudgetError) PayloadBudgetError!void {
    const overhead = std.math.add(usize, transport_overhead_bytes, protocol_overhead_bytes) catch return failure;
    if (mtu_bytes == 0 or overhead >= mtu_bytes) return failure;
}

fn payload_capacity(mtu_bytes: usize, transport_overhead_bytes: usize, protocol_overhead_bytes: usize) usize {
    return mtu_bytes - transport_overhead_bytes - protocol_overhead_bytes;
}

test "payload budgets validate user MTU inputs and negotiate per-route limits" {
    var manager = PayloadBudgetManager{};
    try manager.register_route(7, .{ .transport = .udp, .mtu_bytes = 1_200, .transport_overhead_bytes = 28 });
    const local_offer = try manager.offer(7);
    try std.testing.expectEqual(@as(usize, 1_200), local_offer.mtu_bytes);
    var effective = try manager.negotiate(7, .{ .mtu_bytes = 1_400, .transport_overhead_bytes = 48, .protocol_overhead_bytes = 12 });
    try std.testing.expectEqual(@as(usize, 1_200), effective.effective_mtu_bytes);
    try std.testing.expectEqual(@as(usize, 1_162), effective.payload_bytes);
    effective = try manager.negotiate(7, .{ .mtu_bytes = 1_000, .transport_overhead_bytes = 20, .protocol_overhead_bytes = 20 });
    try std.testing.expectEqual(@as(usize, 960), effective.payload_bytes);
    try std.testing.expectEqual(effective, (try manager.effective_payload_budget(7)).?);
}

test "payload budgets reject malformed offers and route lifecycle failures" {
    var manager = PayloadBudgetManager{};
    try std.testing.expectError(error.InvalidConfiguration, manager.register_route(1, .{ .transport = .udp, .mtu_bytes = 20, .transport_overhead_bytes = 10, .protocol_overhead_bytes = 10 }));
    try manager.register_route(1, .{ .transport = .tcp, .mtu_bytes = 100, .transport_overhead_bytes = 20 });
    try std.testing.expectError(error.RouteAlreadyRegistered, manager.register_route(1, .{ .transport = .tcp, .mtu_bytes = 100, .transport_overhead_bytes = 20 }));
    try std.testing.expectError(error.InvalidOffer, manager.negotiate(1, .{ .mtu_bytes = 20, .transport_overhead_bytes = 10, .protocol_overhead_bytes = 10 }));
    try std.testing.expectError(error.UnknownRoute, manager.offer(2));
    try manager.remove_route(1);
    try std.testing.expectError(error.UnknownRoute, manager.remove_route(1));
}

test "payload budgets bound route registrations" {
    var manager = PayloadBudgetManager{};
    const config = MtuBudgetConfig{ .transport = .udp, .mtu_bytes = 100, .transport_overhead_bytes = 20 };
    for (0..max_payload_budget_routes) |route| try manager.register_route(route, config);
    try std.testing.expectError(error.RouteCapacityExceeded, manager.register_route(max_payload_budget_routes, config));
}
