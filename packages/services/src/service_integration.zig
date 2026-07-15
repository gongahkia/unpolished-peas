const std = @import("std");
const lobby = @import("service_lobby.zig");
const matchmaking = @import("service_matchmaking.zig");
const provider = @import("service_provider.zig");
const relay = @import("service_relay.zig");

test "isolated client lobby match relay and outage flow" {
    var fake = provider.FakeAdapter{};
    const service_provider = fake.provider();
    var lobbies = try lobby.Service.init(std.testing.allocator, service_provider, .{});
    defer lobbies.deinit();
    var matches = try matchmaking.Service.init(std.testing.allocator, &lobbies, .{});
    defer matches.deinit();
    var relays = try relay.Service.init(std.testing.allocator, service_provider, &matches, .{ .max_connections_per_allocation = 2, .max_bandwidth_bytes_per_allocation = 64, .allocation_lifetime_ms = 20 });
    defer relays.deinit();
    const host = try service_provider.issueGuestSession(.{ .now_ms = 1, .lifetime_ms = 100 });
    const client = try service_provider.issueGuestSession(.{ .now_ms = 1, .lifetime_ms = 100 });
    const room = try lobbies.create(host, 2, 100, 1);
    try lobbies.join(room.id, client, 1);
    const host_request = try matches.enqueue(room.id, host, 1);
    const client_request = try matches.enqueue(room.id, client, 1);
    const assignment = (try matches.matchNext(1)) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(assignment.match_id, matches.assignmentFor(host_request.id).?.match_id);
    const host_bootstrap = try relays.bootstrap(host_request.id, host, 1);
    const client_bootstrap = try relays.bootstrap(client_request.id, client, 1);
    const host_route = try host_bootstrap.route(host, 1);
    const client_route = try client_bootstrap.route(client, 1);
    try std.testing.expect(std.crypto.timing_safe.eql([32]u8, host_route.route_key, client_route.route_key));
    const host_lease = try relays.open(host_bootstrap, host, 1);
    const client_lease = try relays.open(client_bootstrap, client, 1);
    try relays.record(client_lease, client, "game-packet".len, 1);
    fake.failure = error.Unavailable;
    try std.testing.expectError(error.Unavailable, relays.record(client_lease, client, 1, 2));
    fake.failure = null;
    try relays.close(client_lease, client, 2);
    try relays.close(host_lease, host, 2);
}
