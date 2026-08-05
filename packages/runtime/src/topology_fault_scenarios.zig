const std = @import("std");
const core = @import("minna-san-core");
const protocol = @import("minna-san-protocol");
const topology = @import("minna-san-topology");
const state = @import("minna-san-state");
const authoritative_host = @import("authoritative_host.zig");
const authoritative_client = @import("authoritative_client.zig");

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

    var clock = core.ManualClock.init(0);
    var host = try authoritative_host.AuthoritativeHost.init(std.testing.allocator, .{ .owner = .dedicated, .clock = clock.clock(), .maximum_peers = 1, .maximum_channels_per_peer = 2, .tick_interval_ns = 1 });
    defer host.deinit();
    var client = try authoritative_client.AuthoritativeClient.init(.{ .local_peer = 2, .host_peer = 1, .input_channel = 10, .event_channel = 11, .maximum_input_bytes = 4 });
    try host.connect_peer(2);
    try host.open_channel(2, 10, .reliable);
    try host.open_channel(2, 11, .reliable);
    try client.connect();
    _ = try client.begin_handshake();
    try client.accept_welcome(.{ .client = 2, .host = 1, .version = protocol.v1_version, .input_channel = 10, .event_channel = 11 });
    const input = try client.send_input("move");
    const routed = try host.route(2, input.channel, .inbound, input.payload);
    try std.testing.expectEqual(protocol.ChannelCapability.reliable, routed.capability);
    try client.consume_authoritative_event(.{ .sequence = 0, .channel = 11, .payload = "state" });

    const SignalingFixture = struct {
        signals: usize = 0,
        fn discover(_: *anyopaque, _: topology.DiscoveryRequest, _: []topology.DiscoveryCandidate) topology.PeerDiscoveryError!usize {
            return 0;
        }
        fn rendezvous(_: *anyopaque, _: topology.RendezvousRequest) topology.PeerDiscoveryError!void {}
        fn signal(context: *anyopaque, _: topology.SignalingMessage) topology.PeerDiscoveryError!void {
            @as(*@This(), @ptrCast(@alignCast(context))).signals += 1;
        }
    };
    var signaling = SignalingFixture{};
    var sharded = try topology.ShardedP2PScheduler.init(std.testing.allocator, .{ .maximum_groups = 1, .maximum_participants = 2, .maximum_dispatches_per_pump = 2, .maximum_signal_bytes = 8, .hooks = .{ .context = &signaling, .discover_fn = SignalingFixture.discover, .rendezvous_fn = SignalingFixture.rendezvous, .signal_fn = SignalingFixture.signal } });
    defer sharded.deinit();
    try sharded.register(1, .{ .peer = 1, .path = .{ .direct = 1 } });
    try sharded.register(1, .{ .peer = 2, .path = .{ .relay = .{ .ingress = 2, .egress = 3 } } });
    try sharded.set_interest(1, 1, true);
    try sharded.set_interest(1, 2, true);
    var dispatches: [2]topology.ShardedP2PDispatch = undefined;
    try std.testing.expectEqual(@as(usize, 2), sharded.schedule(dispatches[0..]));
    try std.testing.expectEqual(topology.PeerGroupPath{ .direct = 1 }, dispatches[0].path);
    try std.testing.expectEqual(topology.PeerGroupPath{ .relay = .{ .ingress = 2, .egress = 3 } }, dispatches[1].path);
    try sharded.signal(1, 1, 2, "offer");
    try std.testing.expectEqual(@as(usize, 1), signaling.signals);
}
