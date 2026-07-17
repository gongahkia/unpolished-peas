const std = @import("std");
const topology = @import("minna-san-topology");
const state = @import("minna-san-state");

fn host_candidate() topology.NatCandidate {
    return .{ .kind = .host, .transport = .udp, .address = .{ .ipv4 = .{ .octets = .{ 1, 1, 1, 1 }, .port = 1 } }, .priority = 1, .expires_at_ns = 100 };
}

test "deterministic P2P partition and migration faults downgrade route prevent split brain transfer state and recover" {
    var checks = try topology.CandidatePairScheduler.init(std.testing.allocator, .{ .maximum_pairs = 1, .maximum_in_flight = 1, .maximum_attempts = 1, .pace_interval_ns = 1, .retry_interval_ns = 1, .check_timeout_ns = 1 });
    defer checks.deinit();
    const pair = try checks.add(host_candidate(), host_candidate(), 1, 0);
    _ = try checks.dispatch(0);
    try checks.complete(pair, false, 1);
    try std.testing.expectEqual(topology.CandidateCheckState.failed, checks.candidate_pair(pair).?.state);

    const selector = try topology.RouteSelector.init(.{ .policy = .direct_first });
    const selected = try selector.select(.{
        .direct = .{ .negotiated = false, .health = .unavailable },
        .relay = .{ .negotiated = true, .health = .healthy },
        .authoritative = .{ .negotiated = false, .health = .unavailable },
    });
    try std.testing.expectEqual(topology.ShardRouteKind.relay, selected.kind);
    var route = try topology.RouteTransition.init(.{ .initial_route = .direct, .initial_security_epoch = 1, .maximum_diagnostics = 2 });
    try route.begin(.relay, 1);
    try route.commit(1);
    try std.testing.expectEqual(topology.RouteTransitionRoute.relay, route.route());

    var coordinator = try state.MigrationCoordinator.init(.{ .initial_host = 1, .initial_term = 1, .initial_membership_revision = 1, .initial_state_revision = 1, .maximum_records = 2 });
    const migration = state.MigrationPlan{ .term = 2, .host = 2, .membership_revision = 1, .membership_count = 2, .host_is_member = true, .health = .healthy, .route = .relay, .route_negotiated = true, .state_revision = 1 };
    try coordinator.begin(migration);
    try coordinator.commit(2, 1);
    try std.testing.expectError(error.StaleTerm, coordinator.begin(migration));

    const transfer = try state.MigrationStateTransfer.init(.{ .maximum_state_bytes = 8, .integrity_key = [_]u8{4} ** 32 });
    const frame = try transfer.create(.{ .metadata = .{ .term = 2, .source_host = 1, .destination_host = 2, .membership_revision = 1, .state_revision = 1, .route = .relay }, .state = "state", .acknowledged = true });
    _ = try transfer.accept(frame, coordinator.current_host());

    var recovery = try topology.AuthoritativeSessionRecovery.init(.{ .maximum_reconnect_attempts = 1 });
    _ = try recovery.begin(.{ .host = coordinator.current_host() });
    _ = try recovery.reconnect_result(true);
    _ = try recovery.resubscribe_result(true);
    _ = try recovery.resync_result(true);
    try std.testing.expectEqual(topology.RecoveryState.recovered, recovery.current_state());
}
