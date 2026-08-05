const std = @import("std");
const networking = @import("minna-san-networking");
const fixtures = @import("minna-san-test-support");

test "networking subsystem shares deterministic clock network and certificate fixtures" {
    var clock = fixtures.DeterministicClock.init(0);
    try clock.advance(1);
    var expected_network = try fixtures.DeterministicNetwork.init(.{ .maximum_messages = 1, .maximum_message_bytes = 1 });
    try expected_network.send("a");
    try std.testing.expectEqual(@as(u64, 0), expected_network.receive().?.sequence);
    const certificate = try fixtures.CertificateFixture.init("networking", 0, 2);
    try certificate.validateAt(clock.now());
    var network = try networking.fault.Network.init(std.testing.allocator, .{ .seed = 1, .latency_ms = 1, .max_flights = 1, .max_inbox_packets = 1 });
    defer network.deinit();
    var sender = networking.fault.Endpoint.init(std.testing.allocator, &network, .{ .id = 1 });
    defer sender.deinit();
    var receiver = networking.fault.Endpoint.init(std.testing.allocator, &network, .{ .id = 2 });
    defer receiver.deinit();
    networking.fault.Endpoint.pair(&sender, &receiver);
    try sender.asTransport().send(.{ .id = 2 }, "a");
    network.advance(1);
    var received = receiver.asTransport().receive().?;
    defer received.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 1), received.from.id);
    try std.testing.expectEqualStrings("a", received.bytes);
}
