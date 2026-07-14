const std = @import("std");
const up = @import("unpolished-peas");
const tools = @import("unpolished-peas-tools");
const services = @import("unpolished-peas-services");

test "downstream module imports remain SDL-free" {
    var canvas = try up.Canvas.init(std.testing.allocator, 1, 1);
    defer canvas.deinit();
    try std.testing.expectEqual(tools.Command.check, tools.parseCommand("check").?);
    try std.testing.expectEqual(tools.Command.docs, tools.parseCommand("docs").?);
    const transport = services.networking.Transport;
    _ = transport;
    const target = try services.ClientTarget.init(services.Endpoint.local());
    try std.testing.expect(target.endpoint.isUsable());
    const authoritative = up.NetContract{ .mode = .authoritative, .role = .listen_host };
    const peer_to_peer = up.NetContract{ .mode = .peer_to_peer, .role = .peer };
    try authoritative.validate();
    try peer_to_peer.validate();
    const identity = try up.NetIdentity.init(1);
    const session = up.NetSession{ .id = 1, .identity = identity, .issued_at_ms = 0, .expires_at_ms = 2 };
    _ = try up.NetConnection.init(authoritative, session, .{ .id = 2 }, 1);
    _ = try up.NetConnection.init(peer_to_peer, session, .{ .id = 2 }, 1);
    const prediction_config = up.PredictionConfig{ .history_limit = 2 };
    var prediction = try up.PredictionClient.init(std.testing.allocator, .{ .id = 2 }, .{}, prediction_config);
    defer prediction.deinit();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const credentials = services.GuestCredentials{
        .identity = services.GuestToken.generate(),
        .session = services.GuestToken.generate(),
        .issued_at_ms = 10,
        .expires_at_ms = 20,
    };
    const store = services.GuestCredentialStore.init(root);
    try store.save(credentials);
    const reused = (try store.loadReusable(15)).?;
    try std.testing.expect(reused.session.eql(credentials.session));
    var fake_provider = services.FakeServiceProvider{};
    const provider = fake_provider.provider();
    const issued = try provider.issueGuestSession(.{ .now_ms = 10, .lifetime_ms = 10 });
    try std.testing.expectEqual(services.ServiceSessionStatus.active, try provider.validateGuestSession(issued.session));
}
