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
}
