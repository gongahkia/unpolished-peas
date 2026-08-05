const std = @import("std");
const services = @import("minna-san-services");
const fixtures = @import("minna-san-test-support");

test "services subsystem shares deterministic process clock certificate and database fixtures" {
    var clock = fixtures.DeterministicClock.init(1);
    try clock.advance(1);
    var process = try fixtures.ProcessFixture.init(.{ .maximum_invocations = 1, .stdout = "1" });
    try std.testing.expectEqualStrings("1", (try process.run("psql")).stdout);
    var database = try fixtures.DatabaseFixture.init(.{ .maximum_queries = 1 });
    try std.testing.expectEqualStrings("1", try database.query("SELECT 1"));
    const certificate = try fixtures.CertificateFixture.init("services", 0, 3);
    try certificate.validateAt(clock.now());
    var fake = services.FakeServiceProvider{};
    const service_provider = fake.provider();
    var lobbies = try services.LobbyService.init(std.testing.allocator, service_provider, .{});
    defer lobbies.deinit();
    const host = try service_provider.issueGuestSession(.{ .now_ms = 1, .lifetime_ms = 10 });
    const lobby = try lobbies.create(host, 1, 10, 1);
    try std.testing.expectEqual(@as(u16, 1), lobby.max_members);
}
