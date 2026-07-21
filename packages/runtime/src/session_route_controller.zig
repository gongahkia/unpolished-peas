const std = @import("std");
const protocol = @import("minna-san-protocol");
const topology = @import("minna-san-topology");
const resource = @import("resource_handle.zig");
const channel_delivery = @import("channel_delivery.zig");

pub const RouteTransitionConsent = struct {
    id: u64,
    approved: bool,
};
pub const SessionRouteEventKind = enum { sent, route_change_began, route_change_committed, route_change_aborted };
pub const SessionRouteEvent = struct {
    kind: SessionRouteEventKind,
    order: u64,
    session: *resource.ResourceHandle,
    from: topology.RouteTransitionRoute,
    to: topology.RouteTransitionRoute,
    channel: ?usize = null,
    semantics: ?channel_delivery.ChannelSemantics = null,
    packet: ?topology.RouteTransitionPacket = null,
};
pub const SessionRouteControllerError = resource.HandleError || channel_delivery.ChannelDeliveryError || topology.RouteTransitionError || error{ InvalidConfiguration, InvalidChannel, ConsentRequired, ConsentMismatch, EventOrderExhausted };
pub const SessionRouteControllerConfig = struct {
    resources: *const resource.ResourceRegistry,
    session: *resource.ResourceHandle,
    initial_route: topology.RouteTransitionRoute,
    initial_security_epoch: protocol.KeyEpoch,
    maximum_diagnostics: usize,
    channels: []const channel_delivery.ChannelDescriptor,
};

pub const SessionRouteController = struct {
    resources: *const resource.ResourceRegistry,
    session: *resource.ResourceHandle,
    channels: []const channel_delivery.ChannelDescriptor,
    transition: topology.RouteTransition,
    pending_consent: ?u64 = null,
    next_event_order: u64 = 0,

    pub fn init(config: SessionRouteControllerConfig) SessionRouteControllerError!SessionRouteController {
        try config.resources.validate_kind(config.session, .session);
        if (config.channels.len == 0) return error.InvalidConfiguration;
        for (config.channels) |channel| try channel.validate();
        return .{
            .resources = config.resources,
            .session = config.session,
            .channels = config.channels,
            .transition = try topology.RouteTransition.init(.{
                .initial_route = config.initial_route,
                .initial_security_epoch = config.initial_security_epoch,
                .maximum_diagnostics = config.maximum_diagnostics,
            }),
        };
    }

    pub fn route(self: SessionRouteController) topology.RouteTransitionRoute {
        return self.transition.route();
    }

    pub fn send(self: *SessionRouteController, channel: usize) SessionRouteControllerError!SessionRouteEvent {
        try self.validateSession();
        const descriptor = self.channelsAt(channel) orelse return error.InvalidChannel;
        const packet = try self.transition.send();
        const order = try self.nextOrder();
        return .{ .kind = .sent, .order = order, .session = self.session, .from = packet.route, .to = packet.route, .channel = channel, .semantics = descriptor.semantics(), .packet = packet };
    }

    pub fn beginRouteChange(self: *SessionRouteController, target: topology.RouteTransitionRoute, security_epoch: protocol.KeyEpoch, consent: RouteTransitionConsent) SessionRouteControllerError!SessionRouteEvent {
        try self.validateSession();
        try requireConsent(consent);
        const source = self.transition.route();
        try self.transition.begin(target, security_epoch);
        self.pending_consent = consent.id;
        return .{ .kind = .route_change_began, .order = try self.nextOrder(), .session = self.session, .from = source, .to = target };
    }

    pub fn commitRouteChange(self: *SessionRouteController, security_epoch: protocol.KeyEpoch, consent: RouteTransitionConsent) SessionRouteControllerError!SessionRouteEvent {
        try self.validateSession();
        try self.requirePendingConsent(consent);
        const source = self.transition.route();
        try self.transition.commit(security_epoch);
        self.pending_consent = null;
        return .{ .kind = .route_change_committed, .order = try self.nextOrder(), .session = self.session, .from = source, .to = self.transition.route() };
    }

    pub fn abortRouteChange(self: *SessionRouteController, security_epoch: protocol.KeyEpoch, consent: RouteTransitionConsent) SessionRouteControllerError!SessionRouteEvent {
        try self.validateSession();
        try self.requirePendingConsent(consent);
        const source = self.transition.route();
        try self.transition.abort(security_epoch);
        self.pending_consent = null;
        return .{ .kind = .route_change_aborted, .order = try self.nextOrder(), .session = self.session, .from = source, .to = source };
    }

    pub fn diagnostics(self: SessionRouteController, output: []topology.RouteTransitionDiagnostic) topology.RouteTransitionError!usize {
        return self.transition.list_diagnostics(output);
    }

    fn validateSession(self: *const SessionRouteController) SessionRouteControllerError!void {
        try self.resources.validate_kind(self.session, .session);
    }

    fn channelsAt(self: SessionRouteController, index: usize) ?channel_delivery.ChannelDescriptor {
        if (index >= self.channels.len) return null;
        return self.channels[index];
    }

    fn requirePendingConsent(self: SessionRouteController, consent: RouteTransitionConsent) SessionRouteControllerError!void {
        try requireConsent(consent);
        if (self.pending_consent == null) return error.ConsentRequired;
        if (self.pending_consent.? != consent.id) return error.ConsentMismatch;
    }

    fn nextOrder(self: *SessionRouteController) SessionRouteControllerError!u64 {
        if (self.next_event_order == std.math.maxInt(u64)) return error.EventOrderExhausted;
        const order = self.next_event_order;
        self.next_event_order += 1;
        return order;
    }
};

fn requireConsent(consent: RouteTransitionConsent) SessionRouteControllerError!void {
    if (consent.id == 0 or !consent.approved) return error.ConsentRequired;
}

test "session route controllers upgrade and downgrade without replacing handles or channel semantics" {
    var resources = try resource.ResourceRegistry.init(std.testing.allocator, 1);
    defer resources.deinit();
    const session = try resources.acquire_kind(.session);
    const channels = [_]channel_delivery.ChannelDescriptor{.{ .delivery = .ordered, .maximum_payload_bytes = 32 }};
    var controller = try SessionRouteController.init(.{ .resources = &resources, .session = session, .initial_route = .relay, .initial_security_epoch = 3, .maximum_diagnostics = 4, .channels = &channels });
    const consent = RouteTransitionConsent{ .id = 7, .approved = true };
    const relay_sent = try controller.send(0);
    try std.testing.expectEqual(@as(u64, 0), relay_sent.order);
    try std.testing.expectEqual(session, relay_sent.session);
    try std.testing.expectEqual(topology.RouteTransitionRoute.relay, relay_sent.packet.?.route);
    try std.testing.expectEqual(channel_delivery.ChannelSemantics{ .reliable = true, .ordering = .ordered, .framing = .messages }, relay_sent.semantics.?);
    try std.testing.expectEqual(@as(u64, 1), (try controller.beginRouteChange(.direct, 3, consent)).order);
    const upgrade = try controller.commitRouteChange(3, consent);
    try std.testing.expectEqual(@as(u64, 2), upgrade.order);
    try std.testing.expectEqual(session, upgrade.session);
    const direct_sent = try controller.send(0);
    try std.testing.expectEqual(@as(u64, 1), direct_sent.packet.?.sequence);
    try std.testing.expectEqual(topology.RouteTransitionRoute.direct, direct_sent.packet.?.route);
    _ = try controller.beginRouteChange(.relay, 3, consent);
    const downgrade = try controller.commitRouteChange(3, consent);
    try std.testing.expectEqual(topology.RouteTransitionRoute.relay, downgrade.to);
    try std.testing.expectEqual(@as(u64, 2), (try controller.send(0)).packet.?.sequence);
    try std.testing.expectEqual(session, controller.session);
}

test "session route controllers require matching consent and retain UDP TCP route options" {
    var resources = try resource.ResourceRegistry.init(std.testing.allocator, 1);
    defer resources.deinit();
    const session = try resources.acquire_kind(.session);
    const channels = [_]channel_delivery.ChannelDescriptor{.{ .delivery = .datagram, .maximum_payload_bytes = 8 }};
    var controller = try SessionRouteController.init(.{ .resources = &resources, .session = session, .initial_route = .udp, .initial_security_epoch = 1, .maximum_diagnostics = 2, .channels = &channels });
    const first = RouteTransitionConsent{ .id = 1, .approved = true };
    try std.testing.expectError(error.ConsentRequired, controller.beginRouteChange(.tcp, 1, .{ .id = 0, .approved = true }));
    _ = try controller.beginRouteChange(.tcp, 1, first);
    try std.testing.expectError(error.ConsentMismatch, controller.commitRouteChange(1, .{ .id = 2, .approved = true }));
    _ = try controller.commitRouteChange(1, first);
    try std.testing.expectEqual(topology.RouteTransitionRoute.tcp, controller.route());
    try std.testing.expectError(error.InvalidChannel, controller.send(1));
    try resources.release_kind(session, .session);
    try std.testing.expectError(error.StaleHandle, controller.send(0));
}
