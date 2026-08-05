const std = @import("std");
const core = @import("minna-san-core");

pub const result_schema_version: u32 = 1;
pub const max_benchmark_peers: usize = 1_000;
pub const max_benchmark_groups: usize = 1_000;
pub const max_benchmark_steps: usize = 10_000;
pub const max_benchmark_payload_bytes: usize = 4_096;
pub const max_benchmark_operations: usize = 1_000_000;
pub const BenchmarkError = core.ClockError || error{ InvalidConfiguration, InvalidArgument, WorkloadTooLarge, ResultTooSmall };

pub const BenchmarkConfig = struct {
    seed: u64 = 0x6d69_6e6e_6173_616e,
    peers: usize = 1,
    groups: usize = 1,
    steps: usize = 16,
    payload_bytes: usize = 64,
    clock_step_ns: core.TimeNs = std.time.ns_per_ms,
};

pub const BenchmarkOperation = struct {
    step: usize,
    peer: usize,
    group: usize,
    payload_word: u64,
    payload_bytes: usize,
};

pub const BenchmarkResult = struct {
    schema_version: u32 = result_schema_version,
    seed: u64,
    peers: usize,
    groups: usize,
    steps: usize,
    payload_bytes: usize,
    operations: usize,
    bytes_processed: usize,
    virtual_duration_ns: core.TimeNs,
    checksum: u64,
};

pub const BenchmarkHarness = struct {
    config: BenchmarkConfig,
    clock: core.ManualClock,
    random: std.Random.DefaultPrng,
    operations: usize = 0,
    bytes_processed: usize = 0,
    checksum: u64 = 0xcbf2_9ce4_8422_2325,

    pub fn init(config: BenchmarkConfig) BenchmarkError!BenchmarkHarness {
        try validateConfig(config);
        return .{ .config = config, .clock = core.ManualClock.init(0), .random = std.Random.DefaultPrng.init(config.seed) };
    }

    pub fn operation(self: *BenchmarkHarness, step: usize, peer: usize) BenchmarkOperation {
        return .{
            .step = step,
            .peer = peer,
            .group = peer % self.config.groups,
            .payload_word = self.random.random().int(u64),
            .payload_bytes = self.config.payload_bytes,
        };
    }

    pub fn record(self: *BenchmarkHarness, event: BenchmarkOperation) BenchmarkError!void {
        if (event.step >= self.config.steps or event.peer >= self.config.peers or event.group >= self.config.groups or event.payload_bytes != self.config.payload_bytes) return error.InvalidArgument;
        self.operations = std.math.add(usize, self.operations, 1) catch return error.WorkloadTooLarge;
        self.bytes_processed = std.math.add(usize, self.bytes_processed, event.payload_bytes) catch return error.WorkloadTooLarge;
        self.checksum = checksum(self.checksum, event);
    }

    pub fn advance(self: *BenchmarkHarness) BenchmarkError!void {
        try self.clock.advance(self.config.clock_step_ns);
    }

    pub fn result(self: BenchmarkHarness) BenchmarkResult {
        return .{
            .seed = self.config.seed,
            .peers = self.config.peers,
            .groups = self.config.groups,
            .steps = self.config.steps,
            .payload_bytes = self.config.payload_bytes,
            .operations = self.operations,
            .bytes_processed = self.bytes_processed,
            .virtual_duration_ns = self.clock.now_ns,
            .checksum = self.checksum,
        };
    }
};

pub fn run(config: BenchmarkConfig) BenchmarkError!BenchmarkResult {
    var harness = try BenchmarkHarness.init(config);
    var step: usize = 0;
    while (step < config.steps) : (step += 1) {
        var peer: usize = 0;
        while (peer < config.peers) : (peer += 1) try harness.record(harness.operation(step, peer));
        try harness.advance();
    }
    return harness.result();
}

pub fn writeJson(result: BenchmarkResult, output: []u8) BenchmarkError![]u8 {
    return std.fmt.bufPrint(output, "{{\"schema_version\":{d},\"seed\":{d},\"peers\":{d},\"groups\":{d},\"steps\":{d},\"payload_bytes\":{d},\"operations\":{d},\"bytes_processed\":{d},\"virtual_duration_ns\":{d},\"checksum\":{d}}}\n", .{ result.schema_version, result.seed, result.peers, result.groups, result.steps, result.payload_bytes, result.operations, result.bytes_processed, result.virtual_duration_ns, result.checksum }) catch return error.ResultTooSmall;
}

pub fn parseArgs(args: []const []const u8) BenchmarkError!BenchmarkConfig {
    var config = BenchmarkConfig{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const value = if (index + 1 < args.len) args[index + 1] else return error.InvalidArgument;
        if (std.mem.eql(u8, args[index], "--seed")) config.seed = parseU64(value) catch return error.InvalidArgument else if (std.mem.eql(u8, args[index], "--peers")) config.peers = parseUsize(value) catch return error.InvalidArgument else if (std.mem.eql(u8, args[index], "--groups")) config.groups = parseUsize(value) catch return error.InvalidArgument else if (std.mem.eql(u8, args[index], "--steps")) config.steps = parseUsize(value) catch return error.InvalidArgument else if (std.mem.eql(u8, args[index], "--payload-bytes")) config.payload_bytes = parseUsize(value) catch return error.InvalidArgument else if (std.mem.eql(u8, args[index], "--clock-step-ns")) config.clock_step_ns = parseU64(value) catch return error.InvalidArgument else return error.InvalidArgument;
        index += 1;
    }
    try validateConfig(config);
    return config;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    const result = try run(try parseArgs(args[1..]));
    var output: [512]u8 = undefined;
    try std.fs.File.stdout().deprecatedWriter().writeAll(try writeJson(result, output[0..]));
}

fn validateConfig(config: BenchmarkConfig) BenchmarkError!void {
    if (config.peers == 0 or config.peers > max_benchmark_peers or config.groups == 0 or config.groups > config.peers or config.groups > max_benchmark_groups or config.steps == 0 or config.steps > max_benchmark_steps or config.payload_bytes == 0 or config.payload_bytes > max_benchmark_payload_bytes or config.clock_step_ns == 0) return error.InvalidConfiguration;
    const operations = std.math.mul(usize, config.peers, config.steps) catch return error.WorkloadTooLarge;
    if (operations > max_benchmark_operations) return error.WorkloadTooLarge;
    _ = std.math.mul(usize, operations, config.payload_bytes) catch return error.WorkloadTooLarge;
}

fn checksum(previous: u64, operation: BenchmarkOperation) u64 {
    var value = previous ^ operation.payload_word;
    value ^= @as(u64, @intCast(operation.step));
    value ^= @as(u64, @intCast(operation.peer)) << 17;
    value ^= @as(u64, @intCast(operation.group)) << 33;
    value ^= @as(u64, @intCast(operation.payload_bytes)) << 49;
    return (value ^ (value >> 30)) *% 0xbf58_476d_1ce4_e5b9;
}

fn parseUsize(value: []const u8) !usize {
    return std.fmt.parseInt(usize, value, 10);
}

fn parseU64(value: []const u8) !u64 {
    return std.fmt.parseInt(u64, value, 10);
}

test "benchmark harness produces stable virtual-clock result records" {
    const config = BenchmarkConfig{ .seed = 7, .peers = 4, .groups = 2, .steps = 3, .payload_bytes = 8, .clock_step_ns = 5 };
    const first = try run(config);
    const second = try run(config);
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(usize, 12), first.operations);
    try std.testing.expectEqual(@as(usize, 96), first.bytes_processed);
    try std.testing.expectEqual(@as(core.TimeNs, 15), first.virtual_duration_ns);
    var json: [512]u8 = undefined;
    const encoded = try writeJson(first, json[0..]);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"schema_version\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"checksum\":") != null);
}

test "benchmark harness rejects malformed and unbounded inputs" {
    try std.testing.expectError(error.InvalidConfiguration, BenchmarkHarness.init(.{ .peers = 0 }));
    try std.testing.expectError(error.InvalidConfiguration, BenchmarkHarness.init(.{ .peers = max_benchmark_peers + 1 }));
    try std.testing.expectError(error.InvalidConfiguration, BenchmarkHarness.init(.{ .peers = 1, .groups = 2 }));
    try std.testing.expectError(error.InvalidConfiguration, BenchmarkHarness.init(.{ .payload_bytes = max_benchmark_payload_bytes + 1 }));
    try std.testing.expectError(error.WorkloadTooLarge, BenchmarkHarness.init(.{ .peers = max_benchmark_peers, .steps = max_benchmark_steps }));
    try std.testing.expectError(error.InvalidArgument, parseArgs(&.{"--peers"}));
    try std.testing.expectError(error.InvalidArgument, parseArgs(&.{ "--peers", "zero" }));
    try std.testing.expectError(error.InvalidArgument, parseArgs(&.{ "--unknown", "1" }));
}
