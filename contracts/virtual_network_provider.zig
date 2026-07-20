const std = @import("std");
const core = @import("minna-san-core");
const networking = @import("minna-san-networking");
const runtime = @import("minna-san-runtime");

pub const max_trace_entries: usize = 4_096;

pub const NatConfig = struct {
    local_policy: networking.nat.NatPolicy = .open,
    remote_policy: networking.nat.NatPolicy = .open,
    allow_relay: bool = true,
    turn_available: bool = true,
};

pub const Config = struct {
    provider_name: []const u8 = "virtual-network",
    poll_work_budget: usize = 1,
    maximum_trace_entries: usize = 256,
    network: networking.fault.Config,
    nat: NatConfig = .{},
};

pub const Direction = enum { first_to_second, second_to_first };
pub const Endpoint = enum { first, second };
pub const TraceKind = enum { initialized, route_selected, route_unavailable, sent, polled, received, torn_down };

pub const TraceEntry = struct {
    kind: TraceKind,
    at_ms: u64,
    route: ?networking.p2p.Route = null,
    from: u64 = 0,
    to: u64 = 0,
    bytes: usize = 0,
    digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = [_]u8{0} ** std.crypto.hash.sha2.Sha256.digest_length,

    pub fn eql(left: TraceEntry, right: TraceEntry) bool {
        return left.kind == right.kind and left.at_ms == right.at_ms and left.route == right.route and left.from == right.from and left.to == right.to and left.bytes == right.bytes and std.mem.eql(u8, &left.digest, &right.digest);
    }
};

pub const VirtualNetworkProvider = struct {
    allocator: std.mem.Allocator,
    config: Config,
    network: *networking.fault.Network,
    first: *networking.fault.Endpoint,
    second: *networking.fault.Endpoint,
    route: ?networking.p2p.Route,
    initialized: bool = false,
    trace_entries: std.ArrayListUnmanaged(TraceEntry) = .empty,

    pub fn init(allocator: std.mem.Allocator, config: Config) !VirtualNetworkProvider {
        if (config.maximum_trace_entries == 0 or config.maximum_trace_entries > max_trace_entries) return error.InvalidConfiguration;
        const network = try allocator.create(networking.fault.Network);
        errdefer allocator.destroy(network);
        network.* = try networking.fault.Network.init(allocator, config.network);
        errdefer network.deinit();
        const first = try allocator.create(networking.fault.Endpoint);
        errdefer allocator.destroy(first);
        first.* = networking.fault.Endpoint.init(allocator, network, .{ .id = 1 });
        errdefer first.deinit();
        const second = try allocator.create(networking.fault.Endpoint);
        errdefer allocator.destroy(second);
        second.* = networking.fault.Endpoint.init(allocator, network, .{ .id = 2 });
        errdefer second.deinit();
        networking.fault.Endpoint.pair(first, second);
        return .{ .allocator = allocator, .config = config, .network = network, .first = first, .second = second, .route = try selectRoute(allocator, config.nat) };
    }

    pub fn deinit(self: *VirtualNetworkProvider) void {
        self.trace_entries.deinit(self.allocator);
        self.second.deinit();
        self.allocator.destroy(self.second);
        self.first.deinit();
        self.allocator.destroy(self.first);
        self.network.deinit();
        self.allocator.destroy(self.network);
        self.* = undefined;
    }

    pub fn provider(self: *VirtualNetworkProvider) runtime.ProviderError!runtime.Provider {
        return runtime.Provider.init(.{ .name = self.config.provider_name, .required_capabilities = .{ .transport_bits = core.transport_capability_bit(.udp), .delivery_bits = core.delivery_capability_bit(.datagrams) }, .poll_work_budget = self.config.poll_work_budget }, self, .{ .init = providerInit, .query_capabilities = queryCapabilities, .poll = providerPoll, .teardown = providerTeardown });
    }

    pub fn send(self: *VirtualNetworkProvider, direction: Direction, bytes: []const u8) !void {
        if (!self.initialized) return error.InvalidState;
        if (self.route == null) return error.RouteUnavailable;
        const Pair = struct { sender: *networking.fault.Endpoint, receiver: *networking.fault.Endpoint };
        const pair: Pair = switch (direction) {
            .first_to_second => .{ .sender = self.first, .receiver = self.second },
            .second_to_first => .{ .sender = self.second, .receiver = self.first },
        };
        try pair.sender.asTransport().send(pair.receiver.peer, bytes);
        try self.record(.{ .kind = .sent, .at_ms = self.network.now_ms, .route = self.route, .from = pair.sender.peer.id, .to = pair.receiver.peer.id, .bytes = bytes.len, .digest = digest(bytes) });
    }

    pub fn receive(self: *VirtualNetworkProvider, endpoint: Endpoint) !?networking.transport.Received {
        const item = switch (endpoint) {
            .first => self.first.asTransport().receive(),
            .second => self.second.asTransport().receive(),
        } orelse return null;
        var received = item;
        errdefer received.deinit(self.allocator);
        try self.record(.{ .kind = .received, .at_ms = self.network.now_ms, .route = self.route, .from = received.from.id, .to = switch (endpoint) {
            .first => self.first.peer.id,
            .second => self.second.peer.id,
        }, .bytes = received.bytes.len, .digest = digest(received.bytes) });
        return received;
    }

    pub fn trace(self: *const VirtualNetworkProvider) []const TraceEntry {
        return self.trace_entries.items;
    }

    fn record(self: *VirtualNetworkProvider, entry: TraceEntry) !void {
        if (self.trace_entries.items.len >= self.config.maximum_trace_entries) return error.TraceLimitExceeded;
        try self.trace_entries.append(self.allocator, entry);
    }

    fn providerInit(context: ?*anyopaque) callconv(.c) c_int {
        const self: *VirtualNetworkProvider = @ptrCast(@alignCast(context orelse return @intFromEnum(core.CResult.invalid_argument)));
        if (self.initialized) return @intFromEnum(core.CResult.invalid_state);
        self.initialized = true;
        self.record(.{ .kind = .initialized, .at_ms = self.network.now_ms }) catch return @intFromEnum(core.CResult.resource_exhausted);
        self.record(.{ .kind = if (self.route == null) .route_unavailable else .route_selected, .at_ms = self.network.now_ms, .route = self.route }) catch return @intFromEnum(core.CResult.resource_exhausted);
        return @intFromEnum(core.CResult.ok);
    }

    fn queryCapabilities(context: ?*anyopaque, out_capabilities: *runtime.ProviderCapabilityDescriptor) callconv(.c) c_int {
        if (context == null) return @intFromEnum(core.CResult.invalid_argument);
        out_capabilities.* = .{ .transport_bits = core.transport_capability_bit(.udp), .delivery_bits = core.delivery_capability_bit(.datagrams) };
        return @intFromEnum(core.CResult.ok);
    }

    fn providerPoll(context: ?*anyopaque, now_ns: core.TimeNs, work_budget: usize, out_result: *runtime.ProviderPollOutput) callconv(.c) c_int {
        const self: *VirtualNetworkProvider = @ptrCast(@alignCast(context orelse return @intFromEnum(core.CResult.invalid_argument)));
        const now_ms = now_ns / std.time.ns_per_ms;
        if (!self.initialized or now_ms < self.network.now_ms) return @intFromEnum(core.CResult.invalid_state);
        const advanced = now_ms > self.network.now_ms;
        if (advanced) self.network.advance(now_ms - self.network.now_ms);
        self.record(.{ .kind = .polled, .at_ms = self.network.now_ms }) catch return @intFromEnum(core.CResult.resource_exhausted);
        out_result.* = .{ .work_completed = if (advanced) @min(@as(usize, 1), work_budget) else 0 };
        return @intFromEnum(core.CResult.ok);
    }

    fn providerTeardown(context: ?*anyopaque) callconv(.c) void {
        const self: *VirtualNetworkProvider = @ptrCast(@alignCast(context orelse return));
        if (!self.initialized) return;
        self.record(.{ .kind = .torn_down, .at_ms = self.network.now_ms }) catch {};
        self.initialized = false;
    }
};

fn selectRoute(allocator: std.mem.Allocator, config: NatConfig) !?networking.p2p.Route {
    const gatherer = try networking.nat.Gatherer.init(.{ .candidate_ttl_ms = 1 });
    var client = try networking.nat.Client.init(allocator, .{ .local_policy = config.local_policy, .remote_policy = config.remote_policy, .allow_relay = config.allow_relay, .turn_available = config.turn_available });
    defer client.deinit();
    try client.addLocalCandidate(try gatherer.host(.{ .id = 1 }, 0));
    try client.addRemoteCandidate(try gatherer.host(.{ .id = 2 }, 0));
    if (config.allow_relay) try client.addLocalCandidate(try gatherer.relay(.{ .id = 3 }, 0));
    return switch (try client.probe(0)) {
        .route => |route| route,
        .failure => null,
    };
}

fn digest(bytes: []const u8) [std.crypto.hash.sha2.Sha256.digest_length]u8 {
    var output: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &output, .{});
    return output;
}

fn replayScenario(allocator: std.mem.Allocator, seed: u64) ![]TraceEntry {
    var adapter = try VirtualNetworkProvider.init(allocator, .{ .network = .{ .seed = seed, .latency_ms = 1, .jitter_ms = 1, .duplicate_per_mille = 1_000, .reorder_per_mille = 1_000, .reorder_delay_ms = 2, .maximum_packet_bytes = 8, .max_flights = 8, .max_inbox_packets = 8 }, .nat = .{ .local_policy = .symmetric, .remote_policy = .open } });
    defer adapter.deinit();
    var clock = core.ManualClock.init(0);
    const sdk = try runtime.SdkConfigBuilder.init().with_clock(clock.clock()).build();
    var platform = try runtime.Runtime.init(allocator, sdk);
    errdefer platform.deinit();
    try platform.registerProvider(try adapter.provider());
    try platform.start();
    try adapter.send(.first_to_second, "one");
    try adapter.send(.first_to_second, "two");
    try clock.advance(4 * std.time.ns_per_ms);
    var result = try platform.poll(.{ .now_ns = clock.clock().now(), .work_budget = 1 });
    result.deinit();
    while (try adapter.receive(.second)) |item| {
        var received = item;
        received.deinit(allocator);
    }
    platform.deinit();
    return try allocator.dupe(TraceEntry, adapter.trace());
}

test "virtual network provider replays seed inputs through runtime lifecycle" {
    const first = try replayScenario(std.testing.allocator, 71);
    defer std.testing.allocator.free(first);
    const second = try replayScenario(std.testing.allocator, 71);
    defer std.testing.allocator.free(second);
    try std.testing.expect(first.len != 0);
    try std.testing.expectEqual(first.len, second.len);
    for (first, second) |left, right| try std.testing.expect(TraceEntry.eql(left, right));
}

test "virtual network provider models loss latency mtu partitions and NAT" {
    var adapter = try VirtualNetworkProvider.init(std.testing.allocator, .{ .network = .{ .seed = 72, .latency_ms = 1, .loss_per_mille = 1_000, .maximum_packet_bytes = 1, .max_flights = 2, .max_inbox_packets = 2 } });
    defer adapter.deinit();
    var provider = try adapter.provider();
    try provider.start();
    defer provider.stop();
    try std.testing.expectError(error.FaultPacketTooLarge, adapter.send(.first_to_second, "mtu"));
    try adapter.send(.first_to_second, "x");
    _ = try provider.poll(std.time.ns_per_ms);
    try std.testing.expect(try adapter.receive(.second) == null);

    var partitioned = try VirtualNetworkProvider.init(std.testing.allocator, .{ .network = .{ .seed = 73, .partitioned = true, .max_flights = 2, .max_inbox_packets = 2 } });
    defer partitioned.deinit();
    var partitioned_provider = try partitioned.provider();
    try partitioned_provider.start();
    defer partitioned_provider.stop();
    try partitioned.send(.first_to_second, "partitioned");
    _ = try partitioned_provider.poll(std.time.ns_per_ms);
    try std.testing.expect(try partitioned.receive(.second) == null);

    var blocked = try VirtualNetworkProvider.init(std.testing.allocator, .{ .network = .{ .seed = 74, .max_flights = 2, .max_inbox_packets = 2 }, .nat = .{ .local_policy = .blocked, .remote_policy = .open, .allow_relay = false } });
    defer blocked.deinit();
    var blocked_provider = try blocked.provider();
    try blocked_provider.start();
    defer blocked_provider.stop();
    try std.testing.expectError(error.RouteUnavailable, blocked.send(.first_to_second, "blocked"));
}
