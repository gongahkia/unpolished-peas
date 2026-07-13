const std = @import("std");
const up = @import("unpolished-peas");
const game_mod = @import("topdown_game.zig");

const player_count = 2;
const input_bytes = 6;
const snapshot_bytes = 21;
const input_tag: u8 = 1;
const snapshot_tag: u8 = 2;

const Replica = struct {
    last_tick: ?u32 = null,
    players: [player_count]up.Vec2 = [_]up.Vec2{.{ .x = 80, .y = 48 }} ** player_count,

    fn poll(self: *Replica, allocator: std.mem.Allocator, endpoint: *up.FaultEndpoint) !void {
        try endpoint.asTransport().poll();
        while (endpoint.asTransport().receive()) |received| {
            var packet = received;
            defer packet.deinit(allocator);
            if (packet.bytes.len != snapshot_bytes or packet.bytes[0] != snapshot_tag) continue;
            const tick = std.mem.readInt(u32, packet.bytes[1..5], .little);
            if (self.last_tick) |last| if (!isAfter(tick, last)) continue;
            for (&self.players, 0..) |*player, index| {
                const offset = 5 + index * 8;
                player.x = @bitCast(std.mem.readInt(u32, packet.bytes[offset..][0..4], .little));
                player.y = @bitCast(std.mem.readInt(u32, packet.bytes[offset + 4 ..][0..4], .little));
            }
            self.last_tick = tick;
        }
    }
};

const Authoritative = struct {
    games: [player_count]game_mod.Game = [_]game_mod.Game{.{}} ** player_count,
    inputs: [player_count]up.Input = [_]up.Input{.{}} ** player_count,
    last_input_tick: [player_count]?u32 = [_]?u32{null} ** player_count,

    fn pollInput(self: *Authoritative, allocator: std.mem.Allocator, endpoint: *up.FaultEndpoint, player_index: usize) !void {
        try endpoint.asTransport().poll();
        while (endpoint.asTransport().receive()) |received| {
            var packet = received;
            defer packet.deinit(allocator);
            if (packet.bytes.len != input_bytes or packet.bytes[0] != input_tag) continue;
            const tick = std.mem.readInt(u32, packet.bytes[1..5], .little);
            if (self.last_input_tick[player_index]) |last| if (!isAfter(tick, last)) continue;
            self.inputs[player_index] = decodeInput(packet.bytes[5]);
            self.last_input_tick[player_index] = tick;
        }
    }

    fn step(self: *Authoritative) void {
        for (&self.games, self.inputs) |*game, input| _ = game.step(input, 1.0 / 60.0);
    }

    fn sendSnapshot(self: *const Authoritative, endpoint: *up.FaultEndpoint, tick: u32) !void {
        var bytes: [snapshot_bytes]u8 = undefined;
        bytes[0] = snapshot_tag;
        std.mem.writeInt(u32, bytes[1..5], tick, .little);
        for (self.games, 0..) |game, index| {
            const offset = 5 + index * 8;
            std.mem.writeInt(u32, bytes[offset..][0..4], @bitCast(game.player.x), .little);
            std.mem.writeInt(u32, bytes[offset + 4 ..][0..4], @bitCast(game.player.y), .little);
        }
        try endpoint.asTransport().send(.{ .id = 1 }, &bytes);
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    try runSmoke(gpa.allocator());
}

pub fn runSmoke(allocator: std.mem.Allocator) !void {
    const config_a = up.FaultNetworkConfig{ .seed = 31, .latency_ms = 2, .jitter_ms = 4, .loss_per_mille = 100, .duplicate_per_mille = 150, .reorder_per_mille = 200, .reorder_delay_ms = 6, .bandwidth_bytes_per_second = 10_000 };
    const config_b = up.FaultNetworkConfig{ .seed = 47, .latency_ms = 3, .jitter_ms = 5, .loss_per_mille = 100, .duplicate_per_mille = 150, .reorder_per_mille = 200, .reorder_delay_ms = 6, .bandwidth_bytes_per_second = 10_000 };
    var network_a = try up.FaultNetwork.init(allocator, config_a);
    defer network_a.deinit();
    var client_a_endpoint = up.FaultEndpoint.init(allocator, &network_a, .{ .id = 1 });
    defer client_a_endpoint.deinit();
    var server_a_endpoint = up.FaultEndpoint.init(allocator, &network_a, .{ .id = 2 });
    defer server_a_endpoint.deinit();
    up.FaultEndpoint.pair(&client_a_endpoint, &server_a_endpoint);
    var network_b = try up.FaultNetwork.init(allocator, config_b);
    defer network_b.deinit();
    var client_b_endpoint = up.FaultEndpoint.init(allocator, &network_b, .{ .id = 1 });
    defer client_b_endpoint.deinit();
    var server_b_endpoint = up.FaultEndpoint.init(allocator, &network_b, .{ .id = 2 });
    defer server_b_endpoint.deinit();
    up.FaultEndpoint.pair(&client_b_endpoint, &server_b_endpoint);

    var authoritative = Authoritative{};
    var client_a = Replica{};
    var client_b = Replica{};
    var tick: u32 = 1;
    while (tick <= 180) : (tick += 1) {
        try sendInput(&client_a_endpoint, tick, 1);
        try sendInput(&client_b_endpoint, tick, 2);
        network_a.advance(16);
        network_b.advance(16);
        try authoritative.pollInput(allocator, &server_a_endpoint, 0);
        try authoritative.pollInput(allocator, &server_b_endpoint, 1);
        authoritative.step();
        try authoritative.sendSnapshot(&server_a_endpoint, tick);
        try authoritative.sendSnapshot(&server_b_endpoint, tick);
        network_a.advance(16);
        network_b.advance(16);
        try client_a.poll(allocator, &client_a_endpoint);
        try client_b.poll(allocator, &client_b_endpoint);
    }
    var final_tick = tick;
    var flush: u32 = 0;
    while (flush < 60) : (flush += 1) {
        try authoritative.sendSnapshot(&server_a_endpoint, final_tick);
        try authoritative.sendSnapshot(&server_b_endpoint, final_tick);
        network_a.advance(16);
        network_b.advance(16);
        try client_a.poll(allocator, &client_a_endpoint);
        try client_b.poll(allocator, &client_b_endpoint);
        final_tick += 1;
    }
    for (authoritative.games, 0..) |game, index| {
        try std.testing.expectEqual(game.player, client_a.players[index]);
        try std.testing.expectEqual(game.player, client_b.players[index]);
    }
}

fn sendInput(endpoint: *up.FaultEndpoint, tick: u32, direction: u8) !void {
    var bytes: [input_bytes]u8 = undefined;
    bytes[0] = input_tag;
    std.mem.writeInt(u32, bytes[1..5], tick, .little);
    bytes[5] = direction;
    try endpoint.asTransport().send(.{ .id = 2 }, &bytes);
}

fn decodeInput(direction: u8) up.Input {
    var input = up.Input{};
    switch (direction) {
        1 => input.set(.right, true),
        2 => input.set(.down, true),
        else => {},
    }
    return input;
}

fn isAfter(value: u32, reference: u32) bool {
    return value != reference and @as(i32, @bitCast(value -% reference)) > 0;
}

test "top-down multiplayer clients converge on seeded authoritative state" {
    try runSmoke(std.testing.allocator);
}
