const std = @import("std");
const contract = @import("net_contract.zig");
const fault = @import("net_fault.zig");
const p2p = @import("net_p2p.zig");
const sync = @import("net_sync.zig");
const Vec2 = @import("math.zig").Vec2;

pub fn run(allocator: std.mem.Allocator) !void {
    try authoritativeConverges(allocator);
    for ([_]p2p.Route{ .direct, .relay }) |route| {
        try p2pDeliversBoundedPacket(allocator, route);
        try p2pFaultsFailDefined(allocator, route, .{ .seed = 701 + @as(u64, @intFromEnum(route)), .loss_per_mille = 1_000, .latency_ms = 2, .max_flights = 8, .max_inbox_packets = 8 });
        try p2pFaultsFailDefined(allocator, route, .{ .seed = 711 + @as(u64, @intFromEnum(route)), .duplicate_per_mille = 1_000, .reorder_per_mille = 1_000, .reorder_delay_ms = 4, .latency_ms = 1, .max_flights = 32, .max_inbox_packets = 32 });
        try malformedPacketFailsDefined(allocator, route);
    }
}

test "fixed seed multiplayer matrix converges or fails defined and bounded" {
    try run(std.testing.allocator);
}

fn authoritativeConverges(allocator: std.mem.Allocator) !void {
    var network = try fault.Network.init(allocator, .{ .seed = 601, .latency_ms = 2, .jitter_ms = 3, .loss_per_mille = 150, .duplicate_per_mille = 150, .reorder_per_mille = 250, .reorder_delay_ms = 7, .bandwidth_bytes_per_second = 10_000, .max_flights = 64, .max_inbox_packets = 64 });
    defer network.deinit();
    var client_endpoint = fault.Endpoint.init(allocator, &network, .{ .id = 1 });
    defer client_endpoint.deinit();
    var server_endpoint = fault.Endpoint.init(allocator, &network, .{ .id = 2 });
    defer server_endpoint.deinit();
    fault.Endpoint.pair(&client_endpoint, &server_endpoint);
    const config = sync.PredictionConfig{ .history_limit = 64, .interpolation = .{ .delay_ms = 16, .max_snapshots = 16 }, .snapshot_history_limit = 16 };
    var client = try sync.PredictionClient.init(allocator, .{ .id = 2 }, .{}, config);
    defer client.deinit();
    var server = try sync.AuthoritativeServer.init(allocator, .{ .id = 1 }, .{}, config);
    defer server.deinit();
    var tick: u32 = 1;
    while (tick <= 32) : (tick += 1) {
        const delta = if (tick % 2 == 0) Vec2{ .x = 1, .y = 0 } else Vec2{ .x = 0, .y = 0.5 };
        try client.submit(client_endpoint.asTransport(), tick, delta);
        try client.retransmitPending(client_endpoint.asTransport());
        network.advance(16);
        try server.poll(server_endpoint.asTransport());
        try server.sendSnapshot(server_endpoint.asTransport(), client.snapshotAcknowledgement());
        network.advance(16);
        try client.poll(client_endpoint.asTransport());
        try std.testing.expect(network.flights.items.len <= network.config.max_flights);
        try std.testing.expect(client_endpoint.queuedPackets() <= network.config.max_inbox_packets);
        try std.testing.expect(server_endpoint.queuedPackets() <= network.config.max_inbox_packets);
        try std.testing.expect(client.history.items.len <= config.history_limit);
    }
    var flush: usize = 0;
    while (flush < 128 and client.history.items.len != 0) : (flush += 1) {
        try client.retransmitPending(client_endpoint.asTransport());
        network.advance(16);
        try server.poll(server_endpoint.asTransport());
        try server.sendSnapshot(server_endpoint.asTransport(), client.snapshotAcknowledgement());
        network.advance(16);
        try client.poll(client_endpoint.asTransport());
    }
    try std.testing.expect(flush < 128);
    try client.assertConverged(server.state);
}

fn p2pDeliversBoundedPacket(allocator: std.mem.Allocator, route: p2p.Route) !void {
    var pair: Pair = undefined;
    try pair.init(allocator, route, .{ .seed = 641 + @as(u64, @intFromEnum(route)), .latency_ms = 2, .jitter_ms = 1, .bandwidth_bytes_per_second = 4_096, .max_flights = 32, .max_inbox_packets = 32 });
    defer pair.deinit();
    try pair.connect(128);
    try std.testing.expectEqual(p2p.State.connected, pair.first.state);
    try std.testing.expectEqual(p2p.State.connected, pair.second.state);
    try pair.second.sendReliable(pair.second_endpoint.asTransport(), "proof-game-packet");
    var attempt: usize = 0;
    while (attempt < 128) : (attempt += 1) {
        pair.network.advance(4);
        try pair.first.poll(pair.first_endpoint.asTransport());
        try pair.second.poll(pair.second_endpoint.asTransport());
        if (pair.first.receive()) |message| {
            var received = message;
            defer received.deinit(allocator);
            try std.testing.expectEqualStrings("proof-game-packet", received.payload);
            return;
        }
        try pair.assertBounds();
    }
    return error.P2pMatrixDeliveryTimeout;
}

fn p2pFaultsFailDefined(allocator: std.mem.Allocator, route: p2p.Route, network_config: fault.Config) !void {
    var pair: Pair = undefined;
    try pair.init(allocator, route, network_config);
    defer pair.deinit();
    try pair.first.begin(pair.first_endpoint.asTransport());
    try pair.second.begin(pair.second_endpoint.asTransport());
    var step: usize = 0;
    while (step < 160 and pair.first.state != .failed and pair.second.state != .failed) : (step += 1) {
        pair.network.advance(4);
        _ = pair.first.poll(pair.first_endpoint.asTransport()) catch {};
        _ = pair.second.poll(pair.second_endpoint.asTransport()) catch {};
        try pair.assertBounds();
    }
    try std.testing.expect(pair.first.state == .failed or pair.second.state == .failed);
    try std.testing.expect(pair.first.failure != null or pair.second.failure != null);
}

fn malformedPacketFailsDefined(allocator: std.mem.Allocator, route: p2p.Route) !void {
    var pair: Pair = undefined;
    try pair.init(allocator, route, .{ .seed = 761 + @as(u64, @intFromEnum(route)), .max_flights = 8, .max_inbox_packets = 8 });
    defer pair.deinit();
    try pair.second_endpoint.asTransport().send(.{ .id = 1 }, &([_]u8{0xa1} ** (p2p.control_bytes + 1)));
    try std.testing.expectError(error.MalformedPeerControl, pair.first.poll(pair.first_endpoint.asTransport()));
    try std.testing.expectEqual(p2p.State.failed, pair.first.state);
    try pair.assertBounds();
}

const Pair = struct {
    network: fault.Network,
    first_endpoint: fault.Endpoint,
    second_endpoint: fault.Endpoint,
    first: p2p.Peer,
    second: p2p.Peer,

    fn init(self: *Pair, allocator: std.mem.Allocator, route: p2p.Route, network_config: fault.Config) !void {
        self.network = try fault.Network.init(allocator, network_config);
        errdefer self.network.deinit();
        self.first_endpoint = fault.Endpoint.init(allocator, &self.network, .{ .id = 1 });
        errdefer self.first_endpoint.deinit();
        self.second_endpoint = fault.Endpoint.init(allocator, &self.network, .{ .id = 2 });
        errdefer self.second_endpoint.deinit();
        fault.Endpoint.pair(&self.first_endpoint, &self.second_endpoint);
        const first_identity = try contract.Identity.init(11);
        const second_identity = try contract.Identity.init(22);
        self.first = try p2p.Peer.init(allocator, .{ .local_identity = first_identity, .remote_identity = second_identity, .session_id = 33, .authentication_token = 44, .expires_at_ms = 1_000, .peer = .{ .id = 2 }, .route = route, .negotiation_timeout_ms = 500 });
        errdefer self.first.deinit();
        self.second = try p2p.Peer.init(allocator, .{ .local_identity = second_identity, .remote_identity = first_identity, .session_id = 33, .authentication_token = 44, .expires_at_ms = 1_000, .peer = .{ .id = 1 }, .route = route, .negotiation_timeout_ms = 500 });
    }

    fn deinit(self: *Pair) void {
        self.second.deinit();
        self.first.deinit();
        self.second_endpoint.deinit();
        self.first_endpoint.deinit();
        self.network.deinit();
    }

    fn connect(self: *Pair, max_steps: usize) !void {
        try self.first.begin(self.first_endpoint.asTransport());
        try self.second.begin(self.second_endpoint.asTransport());
        var step: usize = 0;
        while (step < max_steps and (self.first.state != .connected or self.second.state != .connected)) : (step += 1) {
            self.network.advance(4);
            try self.first.poll(self.first_endpoint.asTransport());
            try self.second.poll(self.second_endpoint.asTransport());
            try self.assertBounds();
        }
    }

    fn assertBounds(self: *const Pair) !void {
        try std.testing.expect(self.network.flights.items.len <= self.network.config.max_flights);
        try std.testing.expect(self.first_endpoint.queuedPackets() <= self.network.config.max_inbox_packets);
        try std.testing.expect(self.second_endpoint.queuedPackets() <= self.network.config.max_inbox_packets);
    }
};
