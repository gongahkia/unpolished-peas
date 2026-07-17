const std = @import("std");
const core = @import("minna-san-core");
const protocol = @import("minna-san-protocol");
const harness = @import("benchmark_harness.zig");

pub const throughput_result_schema_version: u32 = 1;
pub const max_throughput_benchmark_steps: usize = 1_000;
pub const max_throughput_payload_bytes: usize = 1_024;

pub const ThroughputBenchmarkConfig = struct {
    seed: u64 = 4,
    steps: usize = 64,
    payload_bytes: usize = 256,
    loss_interval: usize = 7,
};

pub const ThroughputBenchmarkResult = struct {
    schema_version: u32 = throughput_result_schema_version,
    seed: u64,
    steps: usize,
    payload_bytes: usize,
    virtual_duration_ns: core.TimeNs,
    payload_attempted_bytes: usize,
    payload_admitted_bytes: usize,
    throughput_bytes_per_second: usize,
    paced_bytes: usize,
    pacing_deferrals: usize,
    congestion_window_bytes: usize,
    congestion_loss_events: usize,
    compressed_wire_bytes: usize,
    queue_saturations: usize,
    bandwidth_limited_bytes: usize,
    checksum: u64,
};

pub fn run(config: ThroughputBenchmarkConfig) !ThroughputBenchmarkResult {
    try validateConfig(config);
    var benchmark = try harness.BenchmarkHarness.init(.{ .seed = config.seed, .steps = config.steps, .payload_bytes = config.payload_bytes, .clock_step_ns = std.time.ns_per_ms });
    var congestion = try protocol.BaselineCongestionController.init(.{ .initial_window_bytes = config.payload_bytes * 2, .minimum_window_bytes = config.payload_bytes, .maximum_window_bytes = config.payload_bytes * 8, .maximum_segment_size = config.payload_bytes });
    try congestion.register_route(1);
    const controller = congestion.controller();
    var pacer = try protocol.PacketPacer.init(.{ .bytes_per_second = config.payload_bytes * 1_000, .maximum_burst_bytes = config.payload_bytes, .maximum_timer_ns = std.time.ns_per_ms });
    try pacer.register_route(1, 0);
    const bandwidth_config = protocol.BandwidthCapConfig{
        .ingress = .{ .bytes_per_second = config.payload_bytes * 250, .maximum_burst_bytes = config.payload_bytes * 2, .control_reserve_bytes = config.payload_bytes / 4 },
        .egress = .{ .bytes_per_second = config.payload_bytes * 250, .maximum_burst_bytes = config.payload_bytes * 2, .control_reserve_bytes = config.payload_bytes / 4 },
    };
    var bandwidth = protocol.BandwidthLimiter{};
    try bandwidth.register_route(1, bandwidth_config, 0);
    var backpressure = try protocol.BackpressureController.init(.{ .maximum_queued_bytes = config.payload_bytes, .high_watermark_bytes = config.payload_bytes / 2 });
    const target = protocol.BackpressureTarget{ .transport = 1 };
    try backpressure.register_target(target);
    var codec = try protocol.Lz4BlockCodec.init(.{ .maximum_uncompressed_bytes = config.payload_bytes, .maximum_compressed_bytes = config.payload_bytes + 512 });
    const compression_config = protocol.CompressionConfig{ .maximum_uncompressed_bytes = config.payload_bytes, .maximum_compressed_bytes = config.payload_bytes + 512, .maximum_expansion_ratio = 128 };
    var compression = try protocol.CompressionSession.init(.lz4, compression_config, codec.provider());
    var payload: [max_throughput_payload_bytes]u8 = undefined;
    @memset(payload[0..config.payload_bytes], 0xa5);
    var encoded: [protocol.compression_header_bytes + max_throughput_payload_bytes + 512]u8 = undefined;
    var decoded: [max_throughput_payload_bytes]u8 = undefined;
    var queued_bytes: usize = 0;
    var payload_admitted_bytes: usize = 0;
    var paced_bytes: usize = 0;
    var pacing_deferrals: usize = 0;
    var congestion_loss_events: usize = 0;
    var compressed_wire_bytes: usize = 0;
    var queue_saturations: usize = 0;
    var bandwidth_limited_bytes: usize = 0;
    var step: usize = 0;
    while (step < config.steps) : (step += 1) {
        const now_ns: core.TimeNs = @intCast(step * std.time.ns_per_ms);
        try benchmark.record(benchmark.operation(step, 0));
        const compressed = try compression.compress(payload[0..config.payload_bytes], encoded[0..]);
        if (!std.mem.eql(u8, payload[0..config.payload_bytes], try compression.decompress(compressed, decoded[0..]))) return error.CompressionRoundTripFailed;
        compressed_wire_bytes += compressed.len;
        const reservation = try pacer.reserve(1, controller.send_budget(1), config.payload_bytes, now_ns);
        paced_bytes += reservation.bytes;
        const deferred = try pacer.reserve(1, controller.send_budget(1), 1, now_ns);
        if (deferred.bytes == 0) pacing_deferrals += 1;
        const admitted = try bandwidth.admit(1, .egress, .payload, reservation.bytes, now_ns);
        bandwidth_limited_bytes += reservation.bytes - admitted;
        if (backpressure.reserve(target, admitted)) |_| {
            queued_bytes += admitted;
        } else |err| switch (err) {
            error.QueueFull => {
                queue_saturations += 1;
                _ = try backpressure.release(target, queued_bytes);
                queued_bytes = 0;
                _ = try backpressure.reserve(target, admitted);
                queued_bytes = admitted;
            },
            else => return err,
        }
        controller.on_sent(1, admitted, now_ns);
        const lost = (step + 1) % config.loss_interval == 0;
        controller.on_feedback(1, if (lost) .{ .lost_bytes = admitted, .rtt_ns = std.time.ns_per_ms } else .{ .acknowledged_bytes = admitted, .rtt_ns = std.time.ns_per_ms }, now_ns + std.time.ns_per_ms);
        if (lost) congestion_loss_events += 1;
        payload_admitted_bytes += admitted;
        try benchmark.advance();
    }
    const virtual_duration_ns = benchmark.result().virtual_duration_ns;
    const throughput_bytes_per_second: usize = @intCast((@as(u128, payload_admitted_bytes) * std.time.ns_per_s) / virtual_duration_ns);
    var checksum = benchmark.result().checksum;
    for ([_]u64{
        config.seed,
        @intCast(config.steps),
        @intCast(config.payload_bytes),
        @intCast(payload_admitted_bytes),
        @intCast(paced_bytes),
        @intCast(pacing_deferrals),
        @intCast(congestion.route_state(1).?.congestion_window_bytes),
        @intCast(congestion_loss_events),
        @intCast(compressed_wire_bytes),
        @intCast(queue_saturations),
        @intCast(bandwidth_limited_bytes),
    }) |field| checksum = mix(checksum, field);
    return .{
        .seed = config.seed,
        .steps = config.steps,
        .payload_bytes = config.payload_bytes,
        .virtual_duration_ns = virtual_duration_ns,
        .payload_attempted_bytes = config.steps * config.payload_bytes,
        .payload_admitted_bytes = payload_admitted_bytes,
        .throughput_bytes_per_second = throughput_bytes_per_second,
        .paced_bytes = paced_bytes,
        .pacing_deferrals = pacing_deferrals,
        .congestion_window_bytes = congestion.route_state(1).?.congestion_window_bytes,
        .congestion_loss_events = congestion_loss_events,
        .compressed_wire_bytes = compressed_wire_bytes,
        .queue_saturations = queue_saturations,
        .bandwidth_limited_bytes = bandwidth_limited_bytes,
        .checksum = checksum,
    };
}

pub fn writeJson(result: ThroughputBenchmarkResult, output: []u8) ![]u8 {
    return std.fmt.bufPrint(output, "{{\"schema_version\":{d},\"seed\":{d},\"steps\":{d},\"payload_bytes\":{d},\"virtual_duration_ns\":{d},\"payload_attempted_bytes\":{d},\"payload_admitted_bytes\":{d},\"throughput_bytes_per_second\":{d},\"paced_bytes\":{d},\"pacing_deferrals\":{d},\"congestion_window_bytes\":{d},\"congestion_loss_events\":{d},\"compressed_wire_bytes\":{d},\"queue_saturations\":{d},\"bandwidth_limited_bytes\":{d},\"checksum\":{d}}}\n", .{ result.schema_version, result.seed, result.steps, result.payload_bytes, result.virtual_duration_ns, result.payload_attempted_bytes, result.payload_admitted_bytes, result.throughput_bytes_per_second, result.paced_bytes, result.pacing_deferrals, result.congestion_window_bytes, result.congestion_loss_events, result.compressed_wire_bytes, result.queue_saturations, result.bandwidth_limited_bytes, result.checksum }) catch return error.ResultTooSmall;
}

pub fn main() !void {
    const result = try run(.{});
    var output: [1_024]u8 = undefined;
    try std.fs.File.stdout().deprecatedWriter().writeAll(try writeJson(result, output[0..]));
}

fn mix(previous: u64, field: u64) u64 {
    const value = previous ^ field;
    return (value ^ (value >> 31)) *% 0xd6e8_feb8_6659_fd93;
}

fn validateConfig(config: ThroughputBenchmarkConfig) !void {
    if (config.steps == 0 or config.steps > max_throughput_benchmark_steps or config.payload_bytes < 16 or config.payload_bytes > max_throughput_payload_bytes or config.loss_interval == 0) return error.InvalidConfiguration;
}

test "throughput benchmark measures pacing congestion compression queues and caps" {
    const first = try run(.{ .steps = 16, .payload_bytes = 64, .loss_interval = 4 });
    const second = try run(.{ .steps = 16, .payload_bytes = 64, .loss_interval = 4 });
    try std.testing.expectEqual(@as(core.TimeNs, 16 * std.time.ns_per_ms), first.virtual_duration_ns);
    try std.testing.expect(first.payload_admitted_bytes > 0 and first.payload_admitted_bytes < first.payload_attempted_bytes);
    try std.testing.expect(first.throughput_bytes_per_second > 0);
    try std.testing.expect(first.paced_bytes >= first.payload_admitted_bytes);
    try std.testing.expectEqual(@as(usize, 16), first.pacing_deferrals);
    try std.testing.expectEqual(@as(usize, 4), first.congestion_loss_events);
    try std.testing.expect(first.congestion_window_bytes >= first.payload_bytes);
    try std.testing.expect(first.compressed_wire_bytes < first.payload_attempted_bytes);
    try std.testing.expect(first.queue_saturations > 0);
    try std.testing.expect(first.bandwidth_limited_bytes > 0);
    try std.testing.expectEqual(first, second);
    var json: [1_024]u8 = undefined;
    const encoded = try writeJson(first, json[0..]);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"pacing_deferrals\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"bandwidth_limited_bytes\":") != null);
}

test "throughput benchmark rejects invalid bounded configurations" {
    try std.testing.expectError(error.InvalidConfiguration, run(.{ .steps = 0 }));
    try std.testing.expectError(error.InvalidConfiguration, run(.{ .steps = max_throughput_benchmark_steps + 1 }));
    try std.testing.expectError(error.InvalidConfiguration, run(.{ .payload_bytes = 15 }));
    try std.testing.expectError(error.InvalidConfiguration, run(.{ .payload_bytes = max_throughput_payload_bytes + 1 }));
    try std.testing.expectError(error.InvalidConfiguration, run(.{ .loss_interval = 0 }));
}
