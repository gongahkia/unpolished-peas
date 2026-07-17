const std = @import("std");
const core = @import("minna-san-core");
const runtime = @import("minna-san-runtime");
const networking = @import("minna-san-networking");
const harness = @import("benchmark_harness.zig");

pub const topology_fault_result_schema_version: u32 = 1;
pub const max_topology_fault_packets: usize = 128;

pub const TopologyFaultBenchmarkConfig = struct {
    seed: u64 = 3,
    packets: usize = 64,
};

pub const TopologyFaultBenchmarkResult = struct {
    schema_version: u32 = topology_fault_result_schema_version,
    seed: u64,
    packets: usize,
    delayed_authoritative_before: usize,
    delayed_authoritative: usize,
    delayed_p2p_before: usize,
    delayed_p2p: usize,
    lost_authoritative: usize,
    lost_p2p: usize,
    reordered_authoritative: usize,
    reordered_authoritative_first_sequence: u32,
    reordered_p2p: usize,
    reordered_p2p_first_sequence: u32,
    partitioned_authoritative: usize,
    partitioned_p2p: usize,
    relay_authoritative: usize,
    relay_p2p: usize,
    relay_fallbacks: usize,
    checksum: u64,
};

const Delivery = struct {
    before: usize = 0,
    delivered: usize = 0,
    first_sequence: ?u32 = null,

    fn append(self: *Delivery, sequence: u32) void {
        self.delivered += 1;
        if (self.first_sequence == null) self.first_sequence = sequence;
    }
};

const P2PPair = struct {
    network: networking.fault.Network,
    first_endpoint: networking.fault.Endpoint,
    second_endpoint: networking.fault.Endpoint,
    first: networking.p2p.Peer,
    second: networking.p2p.Peer,

    fn init(self: *P2PPair, allocator: std.mem.Allocator, config: networking.fault.Config, route: networking.p2p.Route) !void {
        self.network = try networking.fault.Network.init(allocator, .{ .seed = config.seed, .maximum_packet_bytes = config.maximum_packet_bytes, .max_flights = config.max_flights, .max_inbox_packets = config.max_inbox_packets });
        errdefer self.network.deinit();
        self.first_endpoint = networking.fault.Endpoint.init(allocator, &self.network, .{ .id = 1 });
        errdefer self.first_endpoint.deinit();
        self.second_endpoint = networking.fault.Endpoint.init(allocator, &self.network, .{ .id = 2 });
        errdefer self.second_endpoint.deinit();
        networking.fault.Endpoint.pair(&self.first_endpoint, &self.second_endpoint);
        const first_identity = try networking.contract.Identity.init(11);
        const second_identity = try networking.contract.Identity.init(22);
        self.first = try networking.p2p.Peer.init(allocator, .{ .local_identity = first_identity, .remote_identity = second_identity, .session_id = 33, .authentication_token = 44, .expires_at_ms = 10_000, .peer = .{ .id = 2 }, .route = route });
        errdefer self.first.deinit();
        self.second = try networking.p2p.Peer.init(allocator, .{ .local_identity = second_identity, .remote_identity = first_identity, .session_id = 33, .authentication_token = 44, .expires_at_ms = 10_000, .peer = .{ .id = 1 }, .route = route });
        errdefer self.second.deinit();
        try self.connect();
        self.network.config = config;
    }

    fn deinit(self: *P2PPair) void {
        self.second.deinit();
        self.first.deinit();
        self.second_endpoint.deinit();
        self.first_endpoint.deinit();
        self.network.deinit();
        self.* = undefined;
    }

    fn connect(self: *P2PPair) !void {
        try self.first.begin(self.first_endpoint.asTransport());
        try self.second.begin(self.second_endpoint.asTransport());
        try self.first.poll(self.first_endpoint.asTransport());
        try self.second.poll(self.second_endpoint.asTransport());
        try self.first.poll(self.first_endpoint.asTransport());
        if (self.first.state != .connected or self.second.state != .connected) return error.PeerNegotiationFailed;
    }
};

pub fn run(config: TopologyFaultBenchmarkConfig) !TopologyFaultBenchmarkResult {
    try validateConfig(config);
    var allocator = std.heap.DebugAllocator(.{ .enable_memory_limit = true }).init;
    defer _ = allocator.deinit();
    var benchmark = try harness.BenchmarkHarness.init(.{ .seed = config.seed, .peers = 2, .groups = 1, .steps = 5, .payload_bytes = 4, .clock_step_ns = std.time.ns_per_ms });
    var step: usize = 0;
    while (step < 5) : (step += 1) {
        var packet: usize = 0;
        while (packet < config.packets) : (packet += 1) try benchmark.record(benchmark.operation(step, packet % 2));
        try benchmark.advance();
    }
    const delayed_config = faultConfig(config, .{ .latency_ms = 5 });
    const delayed_authoritative = try runAuthoritative(allocator.allocator(), delayed_config, config.packets, false, 4, 1);
    const delayed_p2p = try runP2P(allocator.allocator(), delayed_config, config.packets, false, 4, 1, .direct);
    const loss_config = faultConfig(config, .{ .loss_per_mille = 1_000 });
    const lost_authoritative = try runAuthoritative(allocator.allocator(), loss_config, config.packets, false, 0, 1);
    const lost_p2p = try runP2P(allocator.allocator(), loss_config, config.packets, false, 0, 1, .direct);
    const reorder_config = faultConfig(config, .{ .reorder_per_mille = 1_000, .reorder_delay_ms = 5 });
    const reordered_authoritative = try runAuthoritative(allocator.allocator(), reorder_config, config.packets, true, 0, 5);
    const reordered_p2p = try runP2P(allocator.allocator(), reorder_config, config.packets, true, 0, 5, .direct);
    const partition_config = faultConfig(config, .{ .partitioned = true });
    const partitioned_authoritative = try runAuthoritative(allocator.allocator(), partition_config, config.packets, false, 0, 1);
    const partitioned_p2p = try runP2P(allocator.allocator(), partition_config, config.packets, false, 0, 1, .direct);
    const relay_route = try selectRelayFallback(allocator.allocator());
    const relay_config = faultConfig(config, .{});
    const relay_authoritative = try runAuthoritative(allocator.allocator(), relay_config, config.packets, false, 0, 0);
    const relay_p2p = try runP2P(allocator.allocator(), relay_config, config.packets, false, 0, 0, relay_route);
    var checksum = benchmark.result().checksum;
    for ([_]u64{
        config.seed,
        @intCast(config.packets),
        @intCast(delayed_authoritative.before),
        @intCast(delayed_authoritative.delivered),
        @intCast(delayed_p2p.before),
        @intCast(delayed_p2p.delivered),
        @intCast(lost_authoritative.delivered),
        @intCast(lost_p2p.delivered),
        @intCast(reordered_authoritative.delivered),
        reordered_authoritative.first_sequence orelse 0,
        @intCast(reordered_p2p.delivered),
        reordered_p2p.first_sequence orelse 0,
        @intCast(partitioned_authoritative.delivered),
        @intCast(partitioned_p2p.delivered),
        @intCast(relay_authoritative.delivered),
        @intCast(relay_p2p.delivered),
    }) |field| checksum = mix(checksum, field);
    return .{
        .seed = config.seed,
        .packets = config.packets,
        .delayed_authoritative_before = delayed_authoritative.before,
        .delayed_authoritative = delayed_authoritative.delivered,
        .delayed_p2p_before = delayed_p2p.before,
        .delayed_p2p = delayed_p2p.delivered,
        .lost_authoritative = lost_authoritative.delivered,
        .lost_p2p = lost_p2p.delivered,
        .reordered_authoritative = reordered_authoritative.delivered,
        .reordered_authoritative_first_sequence = reordered_authoritative.first_sequence orelse 0,
        .reordered_p2p = reordered_p2p.delivered,
        .reordered_p2p_first_sequence = reordered_p2p.first_sequence orelse 0,
        .partitioned_authoritative = partitioned_authoritative.delivered,
        .partitioned_p2p = partitioned_p2p.delivered,
        .relay_authoritative = relay_authoritative.delivered,
        .relay_p2p = relay_p2p.delivered,
        .relay_fallbacks = if (relay_route == .relay) 1 else 0,
        .checksum = checksum,
    };
}

pub fn writeJson(result: TopologyFaultBenchmarkResult, output: []u8) ![]u8 {
    return std.fmt.bufPrint(output, "{{\"schema_version\":{d},\"seed\":{d},\"packets\":{d},\"delayed_authoritative_before\":{d},\"delayed_authoritative\":{d},\"delayed_p2p_before\":{d},\"delayed_p2p\":{d},\"lost_authoritative\":{d},\"lost_p2p\":{d},\"reordered_authoritative\":{d},\"reordered_authoritative_first_sequence\":{d},\"reordered_p2p\":{d},\"reordered_p2p_first_sequence\":{d},\"partitioned_authoritative\":{d},\"partitioned_p2p\":{d},\"relay_authoritative\":{d},\"relay_p2p\":{d},\"relay_fallbacks\":{d},\"checksum\":{d}}}\n", .{ result.schema_version, result.seed, result.packets, result.delayed_authoritative_before, result.delayed_authoritative, result.delayed_p2p_before, result.delayed_p2p, result.lost_authoritative, result.lost_p2p, result.reordered_authoritative, result.reordered_authoritative_first_sequence, result.reordered_p2p, result.reordered_p2p_first_sequence, result.partitioned_authoritative, result.partitioned_p2p, result.relay_authoritative, result.relay_p2p, result.relay_fallbacks, result.checksum }) catch return error.ResultTooSmall;
}

pub fn main() !void {
    const result = try run(.{});
    var output: [1_024]u8 = undefined;
    try std.fs.File.stdout().deprecatedWriter().writeAll(try writeJson(result, output[0..]));
}

fn faultConfig(config: TopologyFaultBenchmarkConfig, overrides: anytype) networking.fault.Config {
    var result = networking.fault.Config{ .seed = config.seed, .max_flights = config.packets, .max_inbox_packets = config.packets };
    inline for (std.meta.fields(@TypeOf(overrides))) |field| @field(result, field.name) = @field(overrides, field.name);
    return result;
}

fn runAuthoritative(allocator: std.mem.Allocator, config: networking.fault.Config, packets: usize, clear_reorder_after_first: bool, before_ms: u64, after_ms: u64) !Delivery {
    var network = try networking.fault.Network.init(allocator, config);
    defer network.deinit();
    var sender = networking.fault.Endpoint.init(allocator, &network, .{ .id = 1 });
    defer sender.deinit();
    var receiver = networking.fault.Endpoint.init(allocator, &network, .{ .id = 2 });
    defer receiver.deinit();
    networking.fault.Endpoint.pair(&sender, &receiver);
    var clock = core.ManualClock.init(0);
    var host = try runtime.AuthoritativeHost.init(allocator, .{ .owner = .dedicated, .clock = clock.clock(), .maximum_peers = 1, .maximum_channels_per_peer = 1, .tick_interval_ns = 1 });
    defer host.deinit();
    try host.connect_peer(7);
    try host.open_channel(7, 1, .reliable);
    try sendPackets(sender.asTransport(), packets, if (clear_reorder_after_first) &network else null);
    var delivery = Delivery{};
    network.advance(before_ms);
    try drainAuthoritative(&host, receiver.asTransport(), &delivery);
    delivery.before = delivery.delivered;
    network.advance(after_ms);
    try drainAuthoritative(&host, receiver.asTransport(), &delivery);
    return delivery;
}

fn runP2P(allocator: std.mem.Allocator, config: networking.fault.Config, packets: usize, clear_reorder_after_first: bool, before_ms: u64, after_ms: u64, route: networking.p2p.Route) !Delivery {
    var pair: P2PPair = undefined;
    try pair.init(allocator, config, route);
    defer pair.deinit();
    var index: usize = 0;
    while (index < packets) : (index += 1) {
        var payload: [4]u8 = undefined;
        std.mem.writeInt(u32, payload[0..], @intCast(index), .little);
        try pair.first.sendUnreliable(pair.first_endpoint.asTransport(), payload[0..]);
        if (clear_reorder_after_first and index == 0) pair.network.config.reorder_per_mille = 0;
    }
    var delivery = Delivery{};
    pair.network.advance(before_ms);
    try drainP2P(&pair, &delivery);
    delivery.before = delivery.delivered;
    pair.network.advance(after_ms);
    try drainP2P(&pair, &delivery);
    return delivery;
}

fn sendPackets(transport: networking.transport.Transport, packets: usize, network: ?*networking.fault.Network) !void {
    var index: usize = 0;
    while (index < packets) : (index += 1) {
        var payload: [4]u8 = undefined;
        std.mem.writeInt(u32, payload[0..], @intCast(index), .little);
        try transport.send(.{ .id = 2 }, payload[0..]);
        if (network) |value| {
            if (index == 0) value.config.reorder_per_mille = 0;
        }
    }
}

fn drainAuthoritative(host: *runtime.AuthoritativeHost, transport: networking.transport.Transport, delivery: *Delivery) !void {
    while (transport.receive()) |received| {
        var packet = received;
        defer packet.deinit(host.allocator);
        const sequence = try decodeSequence(packet.bytes);
        _ = try host.route(7, 1, .inbound, packet.bytes);
        delivery.append(sequence);
    }
}

fn drainP2P(pair: *P2PPair, delivery: *Delivery) !void {
    try pair.second.poll(pair.second_endpoint.asTransport());
    while (pair.second.receive()) |received| {
        var message = received;
        defer message.deinit(pair.second.allocator);
        delivery.append(try decodeSequence(message.payload));
    }
}

fn selectRelayFallback(allocator: std.mem.Allocator) !networking.p2p.Route {
    const gatherer = try networking.nat.Gatherer.init(.{ .candidate_ttl_ms = 100 });
    var client = try networking.nat.Client.init(allocator, .{ .local_policy = .symmetric, .remote_policy = .open });
    defer client.deinit();
    try client.addLocalCandidate(try gatherer.host(.{ .id = 1 }, 0));
    try client.addLocalCandidate(try gatherer.relay(.{ .id = 3 }, 0));
    try client.addRemoteCandidate(try gatherer.host(.{ .id = 2 }, 0));
    const route = try client.selectRoute(0);
    if (route != .relay) return error.RelayFallbackNotSelected;
    return route;
}

fn decodeSequence(bytes: []const u8) !u32 {
    if (bytes.len != 4) return error.InvalidFaultBenchmarkPayload;
    return std.mem.readInt(u32, bytes[0..4], .little);
}

fn mix(previous: u64, field: u64) u64 {
    const value = previous ^ field;
    return (value ^ (value >> 29)) *% 0x9e37_79b9_7f4a_7c15;
}

fn validateConfig(config: TopologyFaultBenchmarkConfig) !void {
    if (config.packets < 2 or config.packets > max_topology_fault_packets) return error.InvalidConfiguration;
}

test "topology fault benchmark measures bounded authoritative and P2P outcomes" {
    const first = try run(.{ .packets = 8 });
    const second = try run(.{ .packets = 8 });
    try std.testing.expectEqual(@as(usize, 0), first.delayed_authoritative_before);
    try std.testing.expectEqual(@as(usize, 8), first.delayed_authoritative);
    try std.testing.expectEqual(@as(usize, 0), first.delayed_p2p_before);
    try std.testing.expectEqual(@as(usize, 8), first.delayed_p2p);
    try std.testing.expectEqual(@as(usize, 0), first.lost_authoritative);
    try std.testing.expectEqual(@as(usize, 0), first.lost_p2p);
    try std.testing.expectEqual(@as(usize, 8), first.reordered_authoritative);
    try std.testing.expectEqual(@as(u32, 1), first.reordered_authoritative_first_sequence);
    try std.testing.expectEqual(@as(usize, 7), first.reordered_p2p);
    try std.testing.expectEqual(@as(u32, 1), first.reordered_p2p_first_sequence);
    try std.testing.expectEqual(@as(usize, 0), first.partitioned_authoritative);
    try std.testing.expectEqual(@as(usize, 0), first.partitioned_p2p);
    try std.testing.expectEqual(@as(usize, 8), first.relay_authoritative);
    try std.testing.expectEqual(@as(usize, 8), first.relay_p2p);
    try std.testing.expectEqual(@as(usize, 1), first.relay_fallbacks);
    try std.testing.expectEqual(first.checksum, second.checksum);
    var json: [1_024]u8 = undefined;
    const encoded = try writeJson(first, json[0..]);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"partitioned_p2p\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"relay_fallbacks\":1") != null);
}

test "topology fault benchmark rejects unbounded scenarios" {
    try std.testing.expectError(error.InvalidConfiguration, run(.{ .packets = 0 }));
    try std.testing.expectError(error.InvalidConfiguration, run(.{ .packets = 1 }));
    try std.testing.expectError(error.InvalidConfiguration, run(.{ .packets = max_topology_fault_packets + 1 }));
}
