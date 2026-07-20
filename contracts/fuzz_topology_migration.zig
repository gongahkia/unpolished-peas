const std = @import("std");
const topology = @import("minna-san-topology");

test "bounded route-change and authoritative recovery fuzz corpus reaches terminal states" {
    var prng = std.Random.DefaultPrng.init(0x91d3_48a6_ef27_b05c);
    const random = prng.random();
    var transition = try topology.RouteTransition.init(.{ .initial_route = .direct, .initial_security_epoch = 1, .maximum_diagnostics = 4 });
    var iteration: usize = 0;
    while (iteration < 256) : (iteration += 1) {
        switch (random.uintLessThan(u3, 6)) {
            0 => _ = transition.begin(if (transition.route() == .direct) .relay else .direct, if (random.uintLessThan(u8, 2) == 0) transition.current_security_epoch() else random.int(u32)) catch {},
            1 => _ = transition.commit(if (random.uintLessThan(u8, 2) == 0) transition.current_security_epoch() else random.int(u32)) catch {},
            2 => _ = transition.abort(if (random.uintLessThan(u8, 2) == 0) transition.current_security_epoch() else random.int(u32)) catch {},
            3 => _ = transition.update_security_epoch(if (random.uintLessThan(u8, 2) == 0) transition.current_security_epoch() else random.int(u32), if (random.uintLessThan(u8, 2) == 0) transition.current_security_epoch() + 1 else random.int(u32)) catch {},
            4 => {
                if (transition.send() catch null) |packet| _ = transition.receive(packet) catch {};
            },
            5 => _ = transition.receive(.{ .route = if (random.uintLessThan(u8, 2) == 0) transition.route() else if (transition.route() == .direct) .relay else .direct, .sequence = random.int(u64), .security_epoch = random.int(u32) }) catch {},
            else => unreachable,
        }
        try std.testing.expect(transition.diagnostic_count <= transition.config.maximum_diagnostics);
    }
    if (transition.pending_route != null) try transition.abort(transition.current_security_epoch());
    try std.testing.expect(transition.pending_route == null);
    var diagnostics: [4]topology.RouteTransitionDiagnostic = undefined;
    try std.testing.expect((try transition.list_diagnostics(diagnostics[0..])) <= diagnostics.len);

    iteration = 0;
    while (iteration < 64) : (iteration += 1) {
        var recovery = try topology.AuthoritativeSessionRecovery.init(.{ .maximum_reconnect_attempts = random.uintLessThan(u8, 4) + 1 });
        const target: topology.RecoveryTarget = if (iteration % 2 == 0) .{ .host = @intCast(iteration + 1) } else .{ .shard = @intCast(iteration + 1) };
        _ = try recovery.begin(target);
        var step: usize = 0;
        while (step < 16) : (step += 1) {
            switch (recovery.current_state()) {
                .reconnecting => _ = recovery.reconnect_result(random.uintLessThan(u8, 2) != 0) catch {},
                .resubscribing => _ = recovery.resubscribe_result(random.uintLessThan(u8, 2) != 0) catch {},
                .resyncing => _ = recovery.resync_result(random.uintLessThan(u8, 2) != 0) catch {},
                .recovered, .failed => {
                    if (random.uintLessThan(u8, 2) != 0) _ = recovery.begin(target) catch {};
                },
                .idle => _ = recovery.begin(target) catch {},
            }
        }
        while (recovery.current_state() != .recovered and recovery.current_state() != .failed) {
            switch (recovery.current_state()) {
                .reconnecting => _ = try recovery.reconnect_result(false),
                .resubscribing => _ = try recovery.resubscribe_result(false),
                .resyncing => _ = try recovery.resync_result(false),
                .idle, .recovered, .failed => unreachable,
            }
        }
        try std.testing.expect(recovery.current_state() == .recovered or recovery.current_state() == .failed);
    }
}

test "bounded P2P and sharded scheduler fuzz corpus retains selected and bounded states" {
    const ConnectivityFixture = struct {
        accept: bool = true,
        calls: usize = 0,

        fn send(context: *anyopaque, _: topology.ConnectivitySignal) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            return self.accept;
        }
    };
    var prng = std.Random.DefaultPrng.init(0x6e52_ca91_3bd7_04f8);
    const random = prng.random();
    var connectivity_fixture = ConnectivityFixture{};
    const candidate = topology.NatCandidate{ .kind = .host, .transport = .udp, .address = .{ .ipv4 = .{ .octets = .{ 127, 0, 0, 1 }, .port = 3478 } }, .priority = 1, .expires_at_ns = 1_000 };
    var connectivity = try topology.DirectConnectivity.init(std.testing.allocator, .{ .maximum_pairs = 2, .role = .controlling, .tie_breaker = 1, .signaling = .{ .context = &connectivity_fixture, .send_check_fn = ConnectivityFixture.send } });
    defer connectivity.deinit();
    const first = try connectivity.add_pair(candidate, candidate, 2, 0);
    _ = try connectivity.add_pair(candidate, candidate, 1, 0);
    var iteration: usize = 0;
    while (iteration < 128) : (iteration += 1) {
        const pair = random.uintLessThan(usize, 3);
        switch (random.uintLessThan(u3, 5)) {
            0 => {
                connectivity_fixture.accept = random.uintLessThan(u8, 2) != 0;
                _ = connectivity.check(pair, random.uintLessThan(u8, 2) != 0) catch {};
            },
            1 => _ = connectivity.complete_check(pair, random.uintLessThan(u8, 2) != 0) catch {},
            2 => _ = connectivity.nominate(pair) catch {},
            3 => _ = connectivity.resolve_role_conflict(if (random.uintLessThan(u8, 2) == 0) .controlling else .controlled, random.int(u64)) catch {},
            4 => _ = connectivity.direct_route() catch {},
            else => unreachable,
        }
    }
    connectivity_fixture.accept = true;
    if (connectivity.config.role == .controlled) try connectivity.resolve_role_conflict(.controlled, 2);
    switch (connectivity.pairs.items[first].state) {
        .waiting, .failed => try connectivity.check(first, true),
        .in_progress, .succeeded, .nominated => {},
    }
    if (connectivity.pairs.items[first].state == .in_progress) try connectivity.complete_check(first, true);
    if (connectivity.pairs.items[first].state == .succeeded) try connectivity.nominate(first);
    try std.testing.expectEqual(topology.CandidatePairState.nominated, (try connectivity.direct_route()).state);

    const SchedulerFixture = struct {
        reject: bool = false,
        signals: usize = 0,

        fn discover(_: *anyopaque, _: topology.DiscoveryRequest, _: []topology.DiscoveryCandidate) topology.PeerDiscoveryError!usize {
            return 0;
        }

        fn rendezvous(_: *anyopaque, _: topology.RendezvousRequest) topology.PeerDiscoveryError!void {}

        fn signal(context: *anyopaque, _: topology.SignalingMessage) topology.PeerDiscoveryError!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.reject) return error.SignalingFailed;
            self.signals += 1;
        }
    };
    var scheduler_fixture = SchedulerFixture{};
    const hooks = topology.PeerDiscoveryHooks{ .context = &scheduler_fixture, .discover_fn = SchedulerFixture.discover, .rendezvous_fn = SchedulerFixture.rendezvous, .signal_fn = SchedulerFixture.signal };
    var scheduler = try topology.ShardedP2PScheduler.init(std.testing.allocator, .{ .maximum_groups = 2, .maximum_participants = 4, .maximum_dispatches_per_pump = 2, .maximum_signal_bytes = 8, .hooks = hooks });
    defer scheduler.deinit();
    try scheduler.register(1, .{ .peer = 1, .path = .{ .direct = 1 } });
    try scheduler.register(1, .{ .peer = 2, .path = .{ .relay = .{ .ingress = 1, .egress = 2 } } });
    try scheduler.set_interest(1, 1, true);
    try scheduler.signal(1, 1, 2, "ok");
    var payload: [10]u8 = undefined;
    iteration = 0;
    while (iteration < 128) : (iteration += 1) {
        random.bytes(&payload);
        const group: topology.PeerGroupId = random.uintLessThan(u8, 4);
        const peer: topology.PeerGroupPeerId = random.uintLessThan(u8, 6);
        switch (random.uintLessThan(u3, 5)) {
            0 => _ = scheduler.register(group, .{ .peer = peer, .path = if (random.uintLessThan(u8, 2) == 0) .{ .direct = random.uintLessThan(u8, 4) } else .{ .relay = .{ .ingress = random.uintLessThan(u8, 4), .egress = random.uintLessThan(u8, 4) } } }) catch {},
            1 => _ = scheduler.unregister(group, peer) catch {},
            2 => _ = scheduler.set_interest(group, peer, random.uintLessThan(u8, 2) != 0) catch {},
            3 => {
                var dispatches: [2]topology.ShardedP2PDispatch = undefined;
                try std.testing.expect(scheduler.schedule(dispatches[0..]) <= dispatches.len);
            },
            4 => {
                scheduler_fixture.reject = random.uintLessThan(u8, 2) != 0;
                _ = scheduler.signal(group, peer, random.uintLessThan(u8, 6), payload[0..random.uintLessThan(usize, payload.len + 1)]) catch {};
            },
            else => unreachable,
        }
        try std.testing.expect(scheduler.participants.items.len <= scheduler.config.maximum_participants);
        try std.testing.expect(scheduler.group_count <= scheduler.config.maximum_groups);
    }
}

test "bounded host-migration fuzz corpus releases every pending handoff" {
    var prng = std.Random.DefaultPrng.init(0xf0a3_15dc_84e9_62b7);
    const random = prng.random();
    var directory = try topology.ShardDirectory.init(std.testing.allocator, .{ .maximum_shards = 2 });
    defer directory.deinit();
    try directory.register(.{ .id = 1, .capacity = .{ .maximum_participants = 4, .active_participants = 4 }, .health = .healthy, .route = .{ .id = 1, .kind = .authoritative, .endpoint = directory.ShardEndpoint.from_ipv4(.{ .octets = .{ 127, 0, 0, 1 }, .port = 9000 }) } });
    try directory.register(.{ .id = 2, .capacity = .{ .maximum_participants = 4, .active_participants = 0 }, .health = .healthy, .route = .{ .id = 2, .kind = .authoritative, .endpoint = directory.ShardEndpoint.from_ipv4(.{ .octets = .{ 127, 0, 0, 2 }, .port = 9001 }) } });
    var coordinator = try topology.ShardHandoffCoordinator.init(std.testing.allocator, &directory, .{ .maximum_pending_handoffs = 2, .maximum_state_bytes = 4 });
    defer coordinator.deinit();
    var ids: [2]topology.ShardHandoffId = undefined;
    var revisions: [2]u64 = undefined;
    var pending_count: usize = 0;
    var state: [8]u8 = undefined;
    var iteration: usize = 0;
    while (iteration < 128) : (iteration += 1) {
        random.bytes(&state);
        switch (random.uintLessThan(u2, 3)) {
            0 => {
                const source: topology.ShardId = if (random.uintLessThan(u8, 2) == 0) 1 else 2;
                const destination: topology.ShardId = if (random.uintLessThan(u8, 2) == 0) 1 else 2;
                const revision = random.int(u64);
                if (coordinator.prepare(.{ .client = random.uintLessThan(u8, 4), .source = source, .destination = destination, .state_revision = revision, .state = state[0..random.uintLessThan(usize, state.len + 1)] })) |id| {
                    ids[pending_count] = id;
                    revisions[pending_count] = revision;
                    pending_count += 1;
                } else |_| {}
            },
            1 => {
                if (pending_count == 0) {
                    _ = coordinator.acknowledge(random.int(u64), random.int(u64)) catch {};
                } else {
                    const index = random.uintLessThan(usize, pending_count);
                    const revision = if (random.uintLessThan(u8, 2) == 0) revisions[index] else revisions[index] +% 1;
                    if (coordinator.acknowledge(ids[index], revision)) |_| {
                        for (ids[index + 1 .. pending_count], revisions[index + 1 .. pending_count], index..) |id, value, destination| {
                            ids[destination] = id;
                            revisions[destination] = value;
                        }
                        pending_count -= 1;
                    } else |_| {}
                }
            },
            2 => {
                if (pending_count == 0) {
                    _ = coordinator.rollback(random.int(u64)) catch {};
                } else {
                    const index = random.uintLessThan(usize, pending_count);
                    if (coordinator.rollback(ids[index])) |_| {
                        for (ids[index + 1 .. pending_count], revisions[index + 1 .. pending_count], index..) |id, value, destination| {
                            ids[destination] = id;
                            revisions[destination] = value;
                        }
                        pending_count -= 1;
                    } else |_| {}
                }
            },
            else => unreachable,
        }
        try std.testing.expectEqual(pending_count, coordinator.pending_count());
    }
    while (pending_count > 0) {
        pending_count -= 1;
        try coordinator.rollback(ids[pending_count]);
    }
    try std.testing.expectEqual(@as(usize, 0), coordinator.pending_count());
}
