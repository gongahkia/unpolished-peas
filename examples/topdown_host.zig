const std = @import("std");
const up = @import("unpolished-peas");
const game_mod = @import("topdown_game.zig");

pub const Config = struct {
    role: up.NetHostRole,
    bind_address: []const u8 = "127.0.0.1",
    port: u16 = 48081,
    max_peers: u16 = 16,
    ticks: u32 = 60,
};

pub const Report = struct {
    role: up.NetHostRole,
    player: up.Vec2,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var args = try std.process.argsWithAllocator(gpa.allocator());
    defer args.deinit();
    _ = args.next();
    const config = try parseConfig(&args);
    const report = try runSample(gpa.allocator(), config);
    std.debug.print("topdown host: {s} player {d:.2},{d:.2}\n", .{ @tagName(report.role), report.player.x, report.player.y });
}

pub fn runSample(allocator: std.mem.Allocator, config: Config) !Report {
    try validate(config);
    return switch (config.role) {
        .dedicated => runDedicated(allocator, config),
        .listen => runListen(allocator, config),
    };
}

fn runDedicated(allocator: std.mem.Allocator, config: Config) !Report {
    var endpoint = try up.UdpTransport.init(allocator, .{ .bind_address = try std.net.Address.parseIp(config.bind_address, config.port), .receive_buffer_bytes = 16 * 1024, .send_buffer_bytes = 16 * 1024 });
    defer endpoint.deinit();
    var host = try up.NetHost.init(allocator, endpoint.transport(), .{ .role = .dedicated, .peer = .{ .max_peers = config.max_peers } });
    defer host.deinit();
    var game = game_mod.Game{};
    var tick: u32 = 0;
    while (tick < config.ticks) : (tick += 1) {
        try host.poll();
        try stepAuthoritative(allocator, &host, &game);
    }
    return .{ .role = .dedicated, .player = game.player };
}

fn runListen(allocator: std.mem.Allocator, config: Config) !Report {
    var client_endpoint = up.LoopbackTransport.init(allocator, .{ .id = 1 });
    defer client_endpoint.deinit();
    var host_endpoint = up.LoopbackTransport.init(allocator, .{ .id = 2 });
    defer host_endpoint.deinit();
    up.LoopbackTransport.pair(&client_endpoint, &host_endpoint);
    var host = try up.NetHost.init(allocator, host_endpoint.transport(), .{ .role = .listen, .peer = .{ .max_peers = config.max_peers } });
    defer host.deinit();
    var client = try up.NetClient.init(allocator, client_endpoint.transport(), .{});
    try client.connect(.{ .id = 2 }, 1);
    try client.poll();
    try host.poll();
    try client.poll();
    var game = game_mod.Game{};
    var tick: u32 = 0;
    while (tick < config.ticks) : (tick += 1) {
        try client.sendInput("right");
        try client.poll();
        try host.poll();
        try stepAuthoritative(allocator, &host, &game);
    }
    return .{ .role = .listen, .player = game.player };
}

fn stepAuthoritative(allocator: std.mem.Allocator, host: *up.NetHost, game: *game_mod.Game) !void {
    var input = up.Input{};
    while (host.nextEvent()) |received| {
        var event = received;
        defer event.deinit(allocator);
        switch (event) {
            .input => |value| {
                if (std.mem.eql(u8, value.message.payload[up.netPeer.session_token_bytes..], "right")) input.set(.right, true);
            },
            else => {},
        }
    }
    _ = game.step(input, 1.0 / 60.0);
}

fn parseConfig(args: *std.process.ArgIterator) !Config {
    const role_argument = args.next() orelse return usage();
    const role = std.meta.stringToEnum(up.NetHostRole, role_argument) orelse return usage();
    var config = Config{ .role = role };
    while (args.next()) |argument| {
        const value = args.next() orelse return usage();
        if (std.mem.eql(u8, argument, "--bind")) config.bind_address = value else if (std.mem.eql(u8, argument, "--port")) config.port = std.fmt.parseInt(u16, value, 10) catch return usage() else if (std.mem.eql(u8, argument, "--max-peers")) config.max_peers = std.fmt.parseInt(u16, value, 10) catch return usage() else if (std.mem.eql(u8, argument, "--ticks")) config.ticks = std.fmt.parseInt(u32, value, 10) catch return usage() else return usage();
    }
    try validate(config);
    return config;
}

fn validate(config: Config) !void {
    if (config.max_peers == 0 or config.max_peers > 64 or config.ticks == 0 or config.ticks > 100_000) return error.InvalidHostConfiguration;
    _ = std.net.Address.parseIp(config.bind_address, config.port) catch return error.InvalidHostConfiguration;
}

fn usage() error{InvalidArguments} {
    std.debug.print("usage: zig build run-topdown-host -- <dedicated|listen> [--bind <ip>] [--port <u16>] [--max-peers <1..64>] [--ticks <1..100000>]\n", .{});
    return error.InvalidArguments;
}

test "dedicated and listen top-down hosts use shared authoritative game rules" {
    const dedicated = try runSample(std.testing.allocator, .{ .role = .dedicated, .port = 0, .ticks = 1 });
    try std.testing.expectEqual(up.NetHostRole.dedicated, dedicated.role);
    const listen = try runSample(std.testing.allocator, .{ .role = .listen, .ticks = 4 });
    try std.testing.expectEqual(up.NetHostRole.listen, listen.role);
    try std.testing.expect(listen.player.x > dedicated.player.x);
}
