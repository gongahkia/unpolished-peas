const std = @import("std");
const core = @import("minna-san-core");
const protocol = @import("minna-san-protocol");
const topology = @import("minna-san-topology");
const runtime = @import("minna-san-runtime");
const harness = @import("benchmark_harness.zig");

pub const memory_result_schema_version: u32 = 1;
pub const max_memory_benchmark_groups: usize = 100;
pub const max_memory_benchmark_routes_per_group: usize = 100;
pub const max_memory_benchmark_reassembly_bytes: usize = 1_024;

pub const MemoryBenchmarkConfig = struct {
    seed: u64 = 5,
    peers: usize = harness.max_benchmark_peers,
    groups: usize = 10,
    routes_per_group: usize = 100,
    capture_records: usize = runtime.max_capture_streams,
    capture_payload_bytes: usize = 64,
    reassembly_message_bytes: usize = max_memory_benchmark_reassembly_bytes,
};

pub const MemoryBenchmarkResult = struct {
    schema_version: u32 = memory_result_schema_version,
    seed: u64,
    peers: usize,
    groups: usize,
    routes_per_group: usize,
    peer_total_bytes: usize,
    per_peer_bytes: usize,
    group_total_bytes: usize,
    per_group_bytes: usize,
    route_total_bytes: usize,
    per_route_bytes: usize,
    capture_bytes: usize,
    replay_bytes: usize,
    reassembly_bytes: usize,
    checksum: u64,
};

const GroupMeasurements = struct {
    groups: usize,
    routes: usize,
};

pub fn run(config: MemoryBenchmarkConfig) !MemoryBenchmarkResult {
    try validateConfig(config);
    var benchmark = try harness.BenchmarkHarness.init(.{ .seed = config.seed, .peers = config.peers, .groups = config.groups, .steps = 1, .payload_bytes = 1, .clock_step_ns = 1 });
    var peer: usize = 0;
    while (peer < config.peers) : (peer += 1) try benchmark.record(benchmark.operation(0, peer));
    try benchmark.advance();
    const peer_total_bytes = try measurePeers(config.peers);
    const group_measurements = try measureGroups(config.groups, config.routes_per_group);
    const capture_bytes = try measureCapture(config.capture_records, config.capture_payload_bytes);
    const replay_bytes = try measureReplay();
    const reassembly_bytes = try measureReassembly(config.reassembly_message_bytes);
    const total_routes = config.groups * config.routes_per_group;
    var checksum = benchmark.result().checksum;
    for ([_]u64{
        config.seed,
        @intCast(config.peers),
        @intCast(config.groups),
        @intCast(config.routes_per_group),
        @intCast(peer_total_bytes),
        @intCast(group_measurements.groups),
        @intCast(group_measurements.routes),
        @intCast(capture_bytes),
        @intCast(replay_bytes),
        @intCast(reassembly_bytes),
    }) |field| checksum = mix(checksum, field);
    return .{
        .seed = config.seed,
        .peers = config.peers,
        .groups = config.groups,
        .routes_per_group = config.routes_per_group,
        .peer_total_bytes = peer_total_bytes,
        .per_peer_bytes = peer_total_bytes / config.peers,
        .group_total_bytes = group_measurements.groups,
        .per_group_bytes = group_measurements.groups / config.groups,
        .route_total_bytes = group_measurements.routes,
        .per_route_bytes = (group_measurements.routes - group_measurements.groups) / total_routes,
        .capture_bytes = capture_bytes,
        .replay_bytes = replay_bytes,
        .reassembly_bytes = reassembly_bytes,
        .checksum = checksum,
    };
}

pub fn writeJson(result: MemoryBenchmarkResult, output: []u8) ![]u8 {
    return std.fmt.bufPrint(output, "{{\"schema_version\":{d},\"seed\":{d},\"peers\":{d},\"groups\":{d},\"routes_per_group\":{d},\"peer_total_bytes\":{d},\"per_peer_bytes\":{d},\"group_total_bytes\":{d},\"per_group_bytes\":{d},\"route_total_bytes\":{d},\"per_route_bytes\":{d},\"capture_bytes\":{d},\"replay_bytes\":{d},\"reassembly_bytes\":{d},\"checksum\":{d}}}\n", .{ result.schema_version, result.seed, result.peers, result.groups, result.routes_per_group, result.peer_total_bytes, result.per_peer_bytes, result.group_total_bytes, result.per_group_bytes, result.route_total_bytes, result.per_route_bytes, result.capture_bytes, result.replay_bytes, result.reassembly_bytes, result.checksum }) catch return error.ResultTooSmall;
}

pub fn main() !void {
    const result = try run(.{});
    var output: [1_024]u8 = undefined;
    try std.fs.File.stdout().deprecatedWriter().writeAll(try writeJson(result, output[0..]));
}

fn measurePeers(peers: usize) !usize {
    var allocator = std.heap.DebugAllocator(.{ .enable_memory_limit = true }).init;
    defer _ = allocator.deinit();
    var clock = core.ManualClock.init(0);
    var host = try runtime.AuthoritativeHost.init(allocator.allocator(), .{ .owner = .dedicated, .clock = clock.clock(), .maximum_peers = peers, .maximum_channels_per_peer = 1, .tick_interval_ns = 1 });
    defer host.deinit();
    var peer: usize = 0;
    while (peer < peers) : (peer += 1) {
        const id: u64 = @intCast(peer + 1);
        try host.connect_peer(id);
        try host.open_channel(id, 1, .reliable);
    }
    return allocator.total_requested_bytes;
}

fn measureGroups(groups: usize, routes_per_group: usize) !GroupMeasurements {
    var allocator = std.heap.DebugAllocator(.{ .enable_memory_limit = true }).init;
    defer _ = allocator.deinit();
    var routed = try topology.RoutedPeerGroups.init(allocator.allocator(), .{ .maximum_groups = groups, .maximum_routes_per_group = routes_per_group });
    defer routed.deinit();
    var group: usize = 0;
    while (group < groups) : (group += 1) try routed.create(@intCast(group + 1));
    const group_bytes = allocator.total_requested_bytes;
    group = 0;
    while (group < groups) : (group += 1) {
        var route: usize = 0;
        while (route < routes_per_group) : (route += 1) {
            const peer: u64 = @intCast(group * routes_per_group + route + 1);
            try routed.add_route(@intCast(group + 1), .{ .peer = peer, .path = if (route % 2 == 0) .{ .direct = peer } else .{ .relay = .{ .ingress = peer, .egress = peer + 1_000 } } });
        }
    }
    return .{ .groups = group_bytes, .routes = allocator.total_requested_bytes };
}

fn measureCapture(records: usize, payload_bytes: usize) !usize {
    var allocator = std.heap.DebugAllocator(.{ .enable_memory_limit = true }).init;
    defer _ = allocator.deinit();
    var payload: [max_memory_benchmark_reassembly_bytes]u8 = undefined;
    @memset(payload[0..payload_bytes], 0x5a);
    const stream_bytes = runtime.capture_stream_header_bytes + runtime.capture_record_header_bytes + payload_bytes;
    var recorder = try runtime.CaptureRecorder.init(allocator.allocator(), .{ .enabled = true, .maximum_stream_bytes = stream_bytes, .maximum_streams = records });
    defer recorder.deinit();
    var record: usize = 0;
    while (record < records) : (record += 1) try recorder.record(.{ .kind = .packet, .sequence = record, .timestamp_ns = @intCast(record), .payload = payload[0..payload_bytes] });
    return allocator.total_requested_bytes;
}

fn measureReplay() !usize {
    var allocator = std.heap.DebugAllocator(.{ .enable_memory_limit = true }).init;
    defer _ = allocator.deinit();
    var stream: [runtime.capture_stream_header_bytes + runtime.capture_record_header_bytes + 1]u8 = undefined;
    _ = try runtime.encode_capture_stream_header(.{}, stream[0..runtime.capture_stream_header_bytes]);
    _ = try runtime.encode_capture_record(.{ .kind = .event, .sequence = 0, .timestamp_ns = 1, .payload = &.{1} }, stream[runtime.capture_stream_header_bytes..]);
    var clock = core.ManualClock.init(0);
    const sdk = try runtime.SdkConfigBuilder.init().with_clock(clock.clock()).build();
    var polling = runtime.PollRuntime.init(allocator.allocator(), sdk);
    defer polling.deinit();
    var replay = try runtime.CaptureReplay.init(.{ .manual_clock = &clock, .poll_runtime = &polling, .streams = &.{.{ .sequence = 0, .bytes = stream[0..] }} });
    var step = (try replay.poll()) orelse return error.MissingReplayStep;
    defer step.deinit();
    return allocator.total_requested_bytes;
}

fn measureReassembly(message_bytes: usize) !usize {
    var allocator = std.heap.DebugAllocator(.{ .enable_memory_limit = true }).init;
    defer _ = allocator.deinit();
    const fragment_bytes = message_bytes / 2;
    const storage = try allocator.allocator().alloc(u8, message_bytes * protocol.max_reassembly_messages);
    defer allocator.allocator().free(storage);
    var reassembler = try protocol.MessageReassembler.init(.{ .maximum_message_bytes = message_bytes, .fragment_payload_bytes = fragment_bytes, .expiry_ns = 1, .maximum_inflight_messages = protocol.max_reassembly_messages }, storage);
    var payload: [max_memory_benchmark_reassembly_bytes]u8 = undefined;
    @memset(payload[0..fragment_bytes], 0x3c);
    for (0..protocol.max_reassembly_messages) |index| {
        const message_id: u64 = @intCast(index + 1);
        if (try reassembler.accept(.{ .message_id = message_id, .index = 0, .count = 2, .payload = payload[0..fragment_bytes] }, 0) != .pending) return error.ReassemblyUnexpectedCompletion;
    }
    return allocator.total_requested_bytes;
}

fn mix(previous: u64, field: u64) u64 {
    const value = previous ^ field;
    return (value ^ (value >> 28)) *% 0x94d0_49bb_1331_11eb;
}

fn validateConfig(config: MemoryBenchmarkConfig) !void {
    if (config.peers == 0 or config.peers > harness.max_benchmark_peers or config.groups == 0 or config.groups > max_memory_benchmark_groups or config.routes_per_group == 0 or config.routes_per_group > max_memory_benchmark_routes_per_group or config.groups * config.routes_per_group > harness.max_benchmark_peers or config.capture_records == 0 or config.capture_records > runtime.max_capture_streams or config.capture_payload_bytes == 0 or config.capture_payload_bytes > max_memory_benchmark_reassembly_bytes or config.reassembly_message_bytes < 2 or config.reassembly_message_bytes > max_memory_benchmark_reassembly_bytes) return error.InvalidConfiguration;
}

test "memory benchmark measures bounded peer group route capture replay and reassembly ceilings" {
    const first = try run(.{ .peers = 64, .groups = 4, .routes_per_group = 16, .capture_records = 4, .capture_payload_bytes = 32, .reassembly_message_bytes = 128 });
    const second = try run(.{ .peers = 64, .groups = 4, .routes_per_group = 16, .capture_records = 4, .capture_payload_bytes = 32, .reassembly_message_bytes = 128 });
    try std.testing.expect(first.peer_total_bytes >= first.peers);
    try std.testing.expect(first.per_peer_bytes > 0);
    try std.testing.expect(first.group_total_bytes > 0 and first.per_group_bytes > 0);
    try std.testing.expect(first.route_total_bytes > first.group_total_bytes and first.per_route_bytes > 0);
    try std.testing.expect(first.capture_bytes > 0);
    try std.testing.expect(first.replay_bytes > 0);
    try std.testing.expectEqual(@as(usize, 128 * protocol.max_reassembly_messages), first.reassembly_bytes);
    try std.testing.expectEqual(first, second);
    var json: [1_024]u8 = undefined;
    const encoded = try writeJson(first, json[0..]);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"per_route_bytes\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"reassembly_bytes\":") != null);
}

test "memory benchmark rejects invalid bounded configurations" {
    try std.testing.expectError(error.InvalidConfiguration, run(.{ .peers = 0 }));
    try std.testing.expectError(error.InvalidConfiguration, run(.{ .peers = harness.max_benchmark_peers + 1 }));
    try std.testing.expectError(error.InvalidConfiguration, run(.{ .groups = 0 }));
    try std.testing.expectError(error.InvalidConfiguration, run(.{ .groups = 2, .routes_per_group = harness.max_benchmark_peers }));
    try std.testing.expectError(error.InvalidConfiguration, run(.{ .capture_records = runtime.max_capture_streams + 1 }));
    try std.testing.expectError(error.InvalidConfiguration, run(.{ .reassembly_message_bytes = 1 }));
}
