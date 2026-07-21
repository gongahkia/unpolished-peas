const std = @import("std");
const protocol = @import("minna-san-protocol");

pub const max_route_transition_diagnostics: usize = 16;
pub const RouteTransitionRoute = enum { direct, relay, udp, tcp };
pub const RouteTransitionPacket = struct { route: RouteTransitionRoute, sequence: u64, security_epoch: protocol.KeyEpoch };
pub const RouteTransitionDiagnosticKind = enum { began, committed, aborted, epoch_updated };
pub const RouteTransitionDiagnostic = struct {
    kind: RouteTransitionDiagnosticKind,
    from: RouteTransitionRoute,
    to: RouteTransitionRoute,
    sequence: u64,
    security_epoch: protocol.KeyEpoch,
};
pub const RouteTransitionError = error{ InvalidConfiguration, TransitionPending, NoTransition, RouteUnchanged, RouteMismatch, SecurityEpochMismatch, EpochRegression, SendSequenceExhausted, ReceiveSequenceExhausted, ReceiveOutOfOrder, DiagnosticOutputTooSmall };
pub const RouteTransitionConfig = struct {
    initial_route: RouteTransitionRoute,
    initial_security_epoch: protocol.KeyEpoch,
    maximum_diagnostics: usize,
};

pub const RouteTransition = struct {
    config: RouteTransitionConfig,
    active_route: RouteTransitionRoute,
    security_epoch: protocol.KeyEpoch,
    next_send_sequence: u64 = 0,
    next_receive_sequence: u64 = 0,
    pending_route: ?RouteTransitionRoute = null,
    diagnostics: [max_route_transition_diagnostics]RouteTransitionDiagnostic = undefined,
    diagnostic_start: usize = 0,
    diagnostic_count: usize = 0,

    pub fn init(config: RouteTransitionConfig) RouteTransitionError!RouteTransition {
        if (config.maximum_diagnostics == 0 or config.maximum_diagnostics > max_route_transition_diagnostics) return error.InvalidConfiguration;
        return .{ .config = config, .active_route = config.initial_route, .security_epoch = config.initial_security_epoch };
    }
    pub fn route(self: RouteTransition) RouteTransitionRoute {
        return self.active_route;
    }
    pub fn current_security_epoch(self: RouteTransition) protocol.KeyEpoch {
        return self.security_epoch;
    }
    pub fn begin(self: *RouteTransition, target: RouteTransitionRoute, security_epoch: protocol.KeyEpoch) RouteTransitionError!void {
        try self.require_epoch(security_epoch);
        if (self.pending_route != null) return error.TransitionPending;
        if (target == self.active_route) return error.RouteUnchanged;
        self.pending_route = target;
        self.record(.began, self.active_route, target);
    }
    pub fn commit(self: *RouteTransition, security_epoch: protocol.KeyEpoch) RouteTransitionError!void {
        try self.require_epoch(security_epoch);
        const target = self.pending_route orelse return error.NoTransition;
        const source = self.active_route;
        self.active_route = target;
        self.pending_route = null;
        self.record(.committed, source, target);
    }
    pub fn abort(self: *RouteTransition, security_epoch: protocol.KeyEpoch) RouteTransitionError!void {
        try self.require_epoch(security_epoch);
        const target = self.pending_route orelse return error.NoTransition;
        self.pending_route = null;
        self.record(.aborted, self.active_route, target);
    }
    pub fn update_security_epoch(self: *RouteTransition, current: protocol.KeyEpoch, next: protocol.KeyEpoch) RouteTransitionError!void {
        try self.require_epoch(current);
        if (self.pending_route != null) return error.TransitionPending;
        if (next <= current) return error.EpochRegression;
        self.security_epoch = next;
        self.record(.epoch_updated, self.active_route, self.active_route);
    }
    pub fn send(self: *RouteTransition) RouteTransitionError!RouteTransitionPacket {
        if (self.next_send_sequence == std.math.maxInt(u64)) return error.SendSequenceExhausted;
        const packet = RouteTransitionPacket{ .route = self.active_route, .sequence = self.next_send_sequence, .security_epoch = self.security_epoch };
        self.next_send_sequence += 1;
        return packet;
    }
    pub fn receive(self: *RouteTransition, packet: RouteTransitionPacket) RouteTransitionError!void {
        if (packet.route != self.active_route) return error.RouteMismatch;
        try self.require_epoch(packet.security_epoch);
        if (self.next_receive_sequence == std.math.maxInt(u64)) return error.ReceiveSequenceExhausted;
        if (packet.sequence != self.next_receive_sequence) return error.ReceiveOutOfOrder;
        self.next_receive_sequence += 1;
    }
    pub fn list_diagnostics(self: RouteTransition, output: []RouteTransitionDiagnostic) RouteTransitionError!usize {
        if (output.len < self.diagnostic_count) return error.DiagnosticOutputTooSmall;
        for (0..self.diagnostic_count) |index| output[index] = self.diagnostics[(self.diagnostic_start + index) % self.config.maximum_diagnostics];
        return self.diagnostic_count;
    }
    fn require_epoch(self: RouteTransition, security_epoch: protocol.KeyEpoch) RouteTransitionError!void {
        if (security_epoch != self.security_epoch) return error.SecurityEpochMismatch;
    }
    fn record(self: *RouteTransition, kind: RouteTransitionDiagnosticKind, from: RouteTransitionRoute, to: RouteTransitionRoute) void {
        const diagnostic = RouteTransitionDiagnostic{ .kind = kind, .from = from, .to = to, .sequence = self.next_send_sequence, .security_epoch = self.security_epoch };
        if (self.diagnostic_count < self.config.maximum_diagnostics) {
            self.diagnostics[(self.diagnostic_start + self.diagnostic_count) % self.config.maximum_diagnostics] = diagnostic;
            self.diagnostic_count += 1;
            return;
        }
        self.diagnostics[self.diagnostic_start] = diagnostic;
        self.diagnostic_start = (self.diagnostic_start + 1) % self.config.maximum_diagnostics;
    }
};

test "route transitions preserve global ordering and security epochs across downgrade and upgrade" {
    var transition = try RouteTransition.init(.{ .initial_route = .direct, .initial_security_epoch = 7, .maximum_diagnostics = 4 });
    try @import("std").testing.expectEqual(RouteTransitionPacket{ .route = .direct, .sequence = 0, .security_epoch = 7 }, try transition.send());
    try transition.begin(.relay, 7);
    try @import("std").testing.expectEqual(RouteTransitionPacket{ .route = .direct, .sequence = 1, .security_epoch = 7 }, try transition.send());
    try transition.commit(7);
    try @import("std").testing.expectEqual(RouteTransitionPacket{ .route = .relay, .sequence = 2, .security_epoch = 7 }, try transition.send());
    try transition.update_security_epoch(7, 8);
    try @import("std").testing.expectEqual(RouteTransitionPacket{ .route = .relay, .sequence = 3, .security_epoch = 8 }, try transition.send());
    try transition.begin(.direct, 8);
    try transition.commit(8);
    try @import("std").testing.expectEqual(RouteTransitionRoute.direct, transition.route());
    var diagnostics: [4]RouteTransitionDiagnostic = undefined;
    try @import("std").testing.expectEqual(@as(usize, 4), try transition.list_diagnostics(diagnostics[0..]));
    try @import("std").testing.expectEqual(RouteTransitionDiagnosticKind.committed, diagnostics[3].kind);
}

test "route transitions reject unsafe ordering epochs and pending changes" {
    var transition = try RouteTransition.init(.{ .initial_route = .relay, .initial_security_epoch = 1, .maximum_diagnostics = 2 });
    try @import("std").testing.expectError(error.SecurityEpochMismatch, transition.begin(.direct, 2));
    try transition.begin(.direct, 1);
    try @import("std").testing.expectError(error.TransitionPending, transition.update_security_epoch(1, 2));
    try transition.abort(1);
    try @import("std").testing.expectError(error.NoTransition, transition.commit(1));
    try transition.receive(.{ .route = .relay, .sequence = 0, .security_epoch = 1 });
    try @import("std").testing.expectError(error.ReceiveOutOfOrder, transition.receive(.{ .route = .relay, .sequence = 2, .security_epoch = 1 }));
    try @import("std").testing.expectError(error.RouteMismatch, transition.receive(.{ .route = .direct, .sequence = 1, .security_epoch = 1 }));
    try @import("std").testing.expectError(error.EpochRegression, transition.update_security_epoch(1, 1));
    var diagnostics: [1]RouteTransitionDiagnostic = undefined;
    try @import("std").testing.expectError(error.DiagnosticOutputTooSmall, transition.list_diagnostics(diagnostics[0..]));
}
