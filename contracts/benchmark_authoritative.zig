const std = @import("std");
const core = @import("minna-san-core");
const protocol = @import("minna-san-protocol");
const runtime = @import("minna-san-runtime");
const harness = @import("benchmark_harness.zig");

pub const authoritative_result_schema_version: u32 = 1;
pub const max_authoritative_benchmark_steps: usize = 1_000;
pub const max_authoritative_benchmark_payload_bytes: usize = 1_024;
pub const AuthoritativeBenchmarkError = std.mem.Allocator.Error || core.ClockError || runtime.AuthoritativeHostError || harness.BenchmarkError || error{ InvalidConfiguration, ResultTooSmall };

pub const AuthoritativeBenchmarkConfig = struct {
    seed: u64 = 1,
    peers: usize = harness.max_benchmark_peers,
    steps: usize = 16,
    payload_bytes: usize = 128,
    tick_interval_ns: core.TimeNs = std.time.ns_per_ms,
    loss_modulus: u64 = 31,
    fanout_interval: usize = 8,
};

pub const AuthoritativeBenchmarkResult = struct {
    schema_version: u32 = authoritative_result_schema_version,
    seed: u64,
    peers: usize,
    steps: usize,
    payload_bytes: usize,
    route_operations: usize,
    peak_tracked_bytes: usize,
    wall_elapsed_ns: u64,
    virtual_latency_ns: core.TimeNs,
    lost_messages: usize,
    recovered_messages: usize,
    fanout_messages: usize,
    checksum: u64,
};

pub fn run(config: AuthoritativeBenchmarkConfig) AuthoritativeBenchmarkError!AuthoritativeBenchmarkResult {
    try validateConfig(config);
    var allocator = std.heap.DebugAllocator(.{ .enable_memory_limit = true }).init;
    defer _ = allocator.deinit();
    var benchmark = try harness.BenchmarkHarness.init(.{ .seed = config.seed, .peers = config.peers, .groups = 1, .steps = config.steps, .payload_bytes = config.payload_bytes, .clock_step_ns = config.tick_interval_ns });
    var host = try runtime.AuthoritativeHost.init(allocator.allocator(), .{
        .owner = .dedicated,
        .clock = benchmark.clock.clock(),
        .maximum_peers = config.peers,
        .maximum_channels_per_peer = 1,
        .tick_interval_ns = config.tick_interval_ns,
    });
    defer host.deinit();
    var peer: usize = 0;
    while (peer < config.peers) : (peer += 1) {
        const id: u64 = @intCast(peer + 1);
        try host.connect_peer(id);
        try host.open_channel(id, 1, .reliable);
    }
    const peak_tracked_bytes = allocator.total_requested_bytes;
    const started_ns = std.time.nanoTimestamp();
    var payload: [max_authoritative_benchmark_payload_bytes]u8 = undefined;
    @memset(payload[0..config.payload_bytes], 0xa5);
    var route_operations: usize = 0;
    var lost_messages: usize = 0;
    var recovered_messages: usize = 0;
    var fanout_messages: usize = 0;
    var step: usize = 0;
    while (step < config.steps) : (step += 1) {
        _ = try host.tick();
        peer = 0;
        while (peer < config.peers) : (peer += 1) {
            const event = benchmark.operation(step, peer);
            try benchmark.record(event);
            const id: u64 = @intCast(peer + 1);
            if (event.payload_word % config.loss_modulus == 0) {
                lost_messages += 1;
                _ = try host.route(id, 1, .inbound, payload[0..config.payload_bytes]);
                _ = try host.route(id, 1, .outbound, payload[0..config.payload_bytes]);
                route_operations += 2;
                recovered_messages += 1;
            } else {
                _ = try host.route(id, 1, .inbound, payload[0..config.payload_bytes]);
                route_operations += 1;
            }
        }
        if ((step + 1) % config.fanout_interval == 0) {
            peer = 0;
            while (peer < config.peers) : (peer += 1) {
                _ = try host.route(@intCast(peer + 1), 1, .outbound, payload[0..config.payload_bytes]);
                route_operations += 1;
                fanout_messages += 1;
            }
        }
        try benchmark.advance();
    }
    const elapsed = std.time.nanoTimestamp() - started_ns;
    return .{
        .seed = config.seed,
        .peers = config.peers,
        .steps = config.steps,
        .payload_bytes = config.payload_bytes,
        .route_operations = route_operations,
        .peak_tracked_bytes = peak_tracked_bytes,
        .wall_elapsed_ns = @intCast(@max(elapsed, 0)),
        .virtual_latency_ns = config.tick_interval_ns,
        .lost_messages = lost_messages,
        .recovered_messages = recovered_messages,
        .fanout_messages = fanout_messages,
        .checksum = benchmark.result().checksum,
    };
}

pub fn writeJson(result: AuthoritativeBenchmarkResult, output: []u8) AuthoritativeBenchmarkError![]u8 {
    return std.fmt.bufPrint(output, "{{\"schema_version\":{d},\"seed\":{d},\"peers\":{d},\"steps\":{d},\"payload_bytes\":{d},\"route_operations\":{d},\"peak_tracked_bytes\":{d},\"wall_elapsed_ns\":{d},\"virtual_latency_ns\":{d},\"lost_messages\":{d},\"recovered_messages\":{d},\"fanout_messages\":{d},\"checksum\":{d}}}\n", .{ result.schema_version, result.seed, result.peers, result.steps, result.payload_bytes, result.route_operations, result.peak_tracked_bytes, result.wall_elapsed_ns, result.virtual_latency_ns, result.lost_messages, result.recovered_messages, result.fanout_messages, result.checksum }) catch return error.ResultTooSmall;
}

pub fn main() !void {
    const result = try run(.{});
    var output: [512]u8 = undefined;
    try std.fs.File.stdout().deprecatedWriter().writeAll(try writeJson(result, output[0..]));
}

fn validateConfig(config: AuthoritativeBenchmarkConfig) AuthoritativeBenchmarkError!void {
    if (config.peers == 0 or config.peers > harness.max_benchmark_peers or config.steps == 0 or config.steps > max_authoritative_benchmark_steps or config.payload_bytes == 0 or config.payload_bytes > max_authoritative_benchmark_payload_bytes or config.tick_interval_ns == 0 or config.loss_modulus < 2 or config.fanout_interval == 0) return error.InvalidConfiguration;
}

test "authoritative benchmark measures deterministic 1,000-peer lifecycle metrics" {
    const first = try run(.{ .steps = 4, .fanout_interval = 2 });
    const second = try run(.{ .steps = 4, .fanout_interval = 2 });
    try std.testing.expectEqual(@as(usize, 1_000), first.peers);
    try std.testing.expect(first.route_operations >= first.peers * first.steps);
    try std.testing.expect(first.peak_tracked_bytes > 0);
    try std.testing.expectEqual(first.lost_messages, first.recovered_messages);
    try std.testing.expectEqual(@as(usize, 2_000), first.fanout_messages);
    try std.testing.expectEqual(first.checksum, second.checksum);
    try std.testing.expectEqual(first.route_operations, second.route_operations);
    try std.testing.expectEqual(first.virtual_latency_ns, second.virtual_latency_ns);
    var json: [512]u8 = undefined;
    const encoded = try writeJson(first, json[0..]);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"peak_tracked_bytes\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"recovered_messages\":") != null);
}

test "authoritative benchmark rejects invalid bounded scenarios" {
    try std.testing.expectError(error.InvalidConfiguration, run(.{ .peers = 0 }));
    try std.testing.expectError(error.InvalidConfiguration, run(.{ .peers = harness.max_benchmark_peers + 1 }));
    try std.testing.expectError(error.InvalidConfiguration, run(.{ .steps = 0 }));
    try std.testing.expectError(error.InvalidConfiguration, run(.{ .loss_modulus = 1 }));
    try std.testing.expectError(error.InvalidConfiguration, run(.{ .fanout_interval = 0 }));
}
