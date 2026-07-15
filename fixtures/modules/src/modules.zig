const std = @import("std");
const up = @import("unpolished-peas").api;
const ecs = @import("unpolished-peas-ecs");
const networking = @import("unpolished-peas-networking");
const net = networking.networking(up);
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
    const authoritative = net.contract.Config{ .mode = .authoritative, .role = .listen_host };
    const peer_to_peer = net.contract.Config{ .mode = .peer_to_peer, .role = .peer };
    try authoritative.validate();
    try peer_to_peer.validate();
    const identity = try net.contract.Identity.init(1);
    const session = net.contract.Session{ .id = 1, .identity = identity, .issued_at_ms = 0, .expires_at_ms = 2 };
    _ = try net.contract.Connection.init(authoritative, session, .{ .id = 2 }, 1);
    _ = try net.contract.Connection.init(peer_to_peer, session, .{ .id = 2 }, 1);
    const prediction_config = net.sync.PredictionConfig{ .history_limit = 2 };
    var prediction = try net.sync.PredictionClient.init(std.testing.allocator, .{ .id = 2 }, .{}, prediction_config);
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

test "networking core-bound multiplayer matrix" {
    try networking.multiplayerMatrix(up).run(std.testing.allocator);
}

test "networking replication binds the ECS package" {
    const Position = struct { x: i32, y: i32 };
    const replication = networking.replication(ecs);
    const schema = replication.ComponentSchema(Position){
        .id = 1,
        .max_encoded_bytes = 8,
        .encode = struct {
            fn call(destination: []u8, position: Position) ![]u8 {
                if (destination.len < 8) return error.BufferTooSmall;
                std.mem.writeInt(i32, destination[0..4], position.x, .little);
                std.mem.writeInt(i32, destination[4..8], position.y, .little);
                return destination[0..8];
            }
        }.call,
        .decode = struct {
            fn call(source: []const u8) !Position {
                if (source.len != 8) return error.InvalidPosition;
                return .{ .x = std.mem.readInt(i32, source[0..4], .little), .y = std.mem.readInt(i32, source[4..8], .little) };
            }
        }.call,
    };
    var source_world = ecs.World.init(std.testing.allocator);
    defer source_world.deinit();
    var source_positions = ecs.ComponentStore(Position).init(std.testing.allocator);
    defer source_positions.deinit();
    var target_world = ecs.World.init(std.testing.allocator);
    defer target_world.deinit();
    var target_positions = ecs.ComponentStore(Position).init(std.testing.allocator);
    defer target_positions.deinit();
    var source = try replication.Adapter(Position).init(std.testing.allocator, schema);
    defer source.deinit();
    var target = try replication.Adapter(Position).init(std.testing.allocator, schema);
    defer target.deinit();
    const entity = try source_world.create();
    try source_positions.put(&source_world, entity, .{ .x = 1, .y = 2 });
    var spawn = try source.encodeSpawn(&source_world, &source_positions, entity);
    defer spawn.deinit(std.testing.allocator);
    const local = (try target.apply(&target_world, &target_positions, spawn.bytes)).spawned;
    try std.testing.expectEqual(Position{ .x = 1, .y = 2 }, (try target_positions.get(&target_world, local)).*);
    var despawn = try source.encodeDespawn(entity);
    defer despawn.deinit(std.testing.allocator);
    _ = try target.apply(&target_world, &target_positions, despawn.bytes);
    try std.testing.expectError(error.StaleEntity, target_world.validate(local));
}
