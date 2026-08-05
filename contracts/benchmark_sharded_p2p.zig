const std = @import("std");
const core = @import("minna-san-core");
const topology = @import("minna-san-topology");
const harness = @import("benchmark_harness.zig");

pub const sharded_result_schema_version: u32 = 1;
pub const ShardedBenchmarkError = std.mem.Allocator.Error || topology.CandidatePairSchedulerError || topology.ShardedP2PSchedulerError || topology.PeerDiscoveryError || harness.BenchmarkError || error{ InvalidConfiguration, ResultTooSmall };
pub const ShardedBenchmarkConfig = struct {
    seed: u64 = 2,
    peers: usize = harness.max_benchmark_peers,
    groups: usize = 10,
    steps: usize = 16,
    payload_bytes: usize = 64,
    clock_step_ns: core.TimeNs = std.time.ns_per_ms,
};
pub const ShardedBenchmarkResult = struct {
    schema_version: u32 = sharded_result_schema_version,
    seed: u64,
    peers: usize,
    groups: usize,
    steps: usize,
    peak_tracked_bytes: usize,
    wall_elapsed_ns: u64,
    shard_memberships: usize,
    candidate_checks: usize,
    direct_routes: usize,
    relay_routes: usize,
    signals: usize,
    checksum: u64,
};

pub fn run(config: ShardedBenchmarkConfig) ShardedBenchmarkError!ShardedBenchmarkResult {
    try validateConfig(config);
    var allocator = std.heap.DebugAllocator(.{ .enable_memory_limit = true }).init;
    defer _ = allocator.deinit();
    const SignalFixture = struct {
        count: usize = 0,
        fn discover(_: *anyopaque, _: topology.DiscoveryRequest, _: []topology.DiscoveryCandidate) topology.PeerDiscoveryError!usize {
            return 0;
        }
        fn rendezvous(_: *anyopaque, _: topology.RendezvousRequest) topology.PeerDiscoveryError!void {}
        fn signal(context: *anyopaque, _: topology.SignalingMessage) topology.PeerDiscoveryError!void {
            @as(*@This(), @ptrCast(@alignCast(context))).count += 1;
        }
    };
    var signals = SignalFixture{};
    var scheduler = try topology.ShardedP2PScheduler.init(allocator.allocator(), .{ .maximum_groups = config.groups, .maximum_participants = config.peers, .maximum_dispatches_per_pump = config.peers, .maximum_signal_bytes = config.payload_bytes, .hooks = .{ .context = &signals, .discover_fn = SignalFixture.discover, .rendezvous_fn = SignalFixture.rendezvous, .signal_fn = SignalFixture.signal } });
    defer scheduler.deinit();
    var checks = try topology.CandidatePairScheduler.init(allocator.allocator(), .{ .maximum_pairs = config.peers, .maximum_in_flight = 1, .maximum_attempts = 1, .pace_interval_ns = 1, .retry_interval_ns = 1, .check_timeout_ns = 1 });
    defer checks.deinit();
    var peer: usize = 0;
    while (peer < config.peers) : (peer += 1) {
        const group: u64 = @intCast(peer % config.groups + 1);
        const id: u64 = @intCast(peer + 1);
        try scheduler.register(group, .{ .peer = id, .path = if (peer % 2 == 0) .{ .direct = id } else .{ .relay = .{ .ingress = id, .egress = id + config.peers } } });
        try scheduler.set_interest(group, id, true);
        _ = try checks.add(candidate(if (peer % 2 == 0) .host else .relay, id), candidate(.host, id + config.peers), @intCast(peer + 1), 0);
    }
    var candidate_checks: usize = 0;
    var candidate_direct: usize = 0;
    var candidate_relay: usize = 0;
    var now_ns: core.TimeNs = 0;
    while (candidate_checks < config.peers) : (candidate_checks += 1) {
        const dispatch = try checks.dispatch(now_ns);
        if (dispatch.route == .direct) candidate_direct += 1 else candidate_relay += 1;
        try checks.complete(dispatch.pair, true, now_ns);
        now_ns += 1;
    }
    const peak_tracked_bytes = allocator.total_requested_bytes;
    var benchmark = try harness.BenchmarkHarness.init(.{ .seed = config.seed, .peers = config.peers, .groups = config.groups, .steps = config.steps, .payload_bytes = config.payload_bytes, .clock_step_ns = config.clock_step_ns });
    var dispatches: [harness.max_benchmark_peers]topology.ShardedP2PDispatch = undefined;
    var direct_routes: usize = candidate_direct;
    var relay_routes: usize = candidate_relay;
    const started_ns = std.time.nanoTimestamp();
    var step: usize = 0;
    while (step < config.steps) : (step += 1) {
        peer = 0;
        while (peer < config.peers) : (peer += 1) try benchmark.record(benchmark.operation(step, peer));
        const dispatched = scheduler.schedule(dispatches[0..]);
        for (dispatches[0..dispatched]) |dispatch| switch (dispatch.path) {
            .direct => direct_routes += 1,
            .relay => relay_routes += 1,
        };
        var group: usize = 0;
        while (group < config.groups) : (group += 1) {
            const sender: u64 = @intCast(group + 1);
            const recipient: u64 = @intCast(group + 1 + config.groups);
            try scheduler.signal(@intCast(group + 1), sender, recipient, "p");
        }
        try benchmark.advance();
    }
    const elapsed = std.time.nanoTimestamp() - started_ns;
    return .{ .seed = config.seed, .peers = config.peers, .groups = config.groups, .steps = config.steps, .peak_tracked_bytes = peak_tracked_bytes, .wall_elapsed_ns = @intCast(@max(elapsed, 0)), .shard_memberships = config.peers, .candidate_checks = candidate_checks, .direct_routes = direct_routes, .relay_routes = relay_routes, .signals = signals.count, .checksum = benchmark.result().checksum };
}

pub fn writeJson(result: ShardedBenchmarkResult, output: []u8) ShardedBenchmarkError![]u8 {
    return std.fmt.bufPrint(output, "{{\"schema_version\":{d},\"seed\":{d},\"peers\":{d},\"groups\":{d},\"steps\":{d},\"peak_tracked_bytes\":{d},\"wall_elapsed_ns\":{d},\"shard_memberships\":{d},\"candidate_checks\":{d},\"direct_routes\":{d},\"relay_routes\":{d},\"signals\":{d},\"checksum\":{d}}}\n", .{ result.schema_version, result.seed, result.peers, result.groups, result.steps, result.peak_tracked_bytes, result.wall_elapsed_ns, result.shard_memberships, result.candidate_checks, result.direct_routes, result.relay_routes, result.signals, result.checksum }) catch return error.ResultTooSmall;
}

pub fn main() !void {
    const result = try run(.{});
    var output: [512]u8 = undefined;
    try std.fs.File.stdout().deprecatedWriter().writeAll(try writeJson(result, output[0..]));
}

fn candidate(kind: topology.NatCandidateKind, id: u64) topology.NatCandidate {
    const port: u16 = @intCast(10_000 + id % 40_000);
    return .{ .kind = kind, .transport = .udp, .address = .{ .ipv4 = .{ .octets = .{ 198, 51, 100, @truncate(id) }, .port = port } }, .priority = 1, .expires_at_ns = std.math.maxInt(core.TimeNs), .credentials = if (kind == .relay) .{ .username = "u", .password = "p", .expires_at_ns = std.math.maxInt(core.TimeNs) } else null };
}

fn validateConfig(config: ShardedBenchmarkConfig) ShardedBenchmarkError!void {
    if (config.peers == 0 or config.peers > harness.max_benchmark_peers or config.groups == 0 or config.groups > config.peers / 2 or config.steps == 0 or config.steps > harness.max_benchmark_steps or config.payload_bytes == 0 or config.payload_bytes > harness.max_benchmark_payload_bytes or config.clock_step_ns == 0) return error.InvalidConfiguration;
}

test "sharded P2P benchmark measures deterministic 1,000-peer membership and routes" {
    const first = try run(.{ .steps = 2 });
    const second = try run(.{ .steps = 2 });
    try std.testing.expectEqual(@as(usize, 1_000), first.shard_memberships);
    try std.testing.expectEqual(@as(usize, 1_000), first.candidate_checks);
    try std.testing.expect(first.direct_routes > 0 and first.relay_routes > 0);
    try std.testing.expectEqual(@as(usize, 20), first.signals);
    try std.testing.expect(first.peak_tracked_bytes > 0);
    try std.testing.expectEqual(first.checksum, second.checksum);
}

test "sharded P2P benchmark rejects invalid bounded scenarios" {
    try std.testing.expectError(error.InvalidConfiguration, run(.{ .peers = 0 }));
    try std.testing.expectError(error.InvalidConfiguration, run(.{ .peers = harness.max_benchmark_peers + 1 }));
    try std.testing.expectError(error.InvalidConfiguration, run(.{ .peers = 4, .groups = 3 }));
    try std.testing.expectError(error.InvalidConfiguration, run(.{ .steps = 0 }));
}
