const std = @import("std");
const handshake = @import("net_handshake.zig");
const net_codec = @import("net_codec.zig");
const net_contract = @import("net_contract.zig");
const net_peer = @import("net_peer.zig");
const transport = @import("net_transport.zig");

pub const HostRole = enum { dedicated, listen };
pub const HostConfig = struct {
    role: HostRole = .listen,
    peer: net_peer.Config = .{},
};
pub const ClientConfig = struct {
    handshake: handshake.ClientConfig = .{},
    heartbeat_interval_ms: u64 = 1_000,
};

pub const Host = struct { // owns its peer server and borrows Transport; call deinit before the transport owner.
    transport: transport.Transport,
    role: HostRole,
    peers: net_peer.Server,

    pub fn init(allocator: std.mem.Allocator, net: transport.Transport, config: HostConfig) !Host {
        if (config.peer.max_peers > 64) return error.InvalidSessionConfig;
        try (net_contract.Config{
            .mode = .authoritative,
            .role = switch (config.role) {
                .dedicated => .dedicated_host,
                .listen => .listen_host,
            },
            .protocol_version = config.peer.protocol_version,
            .max_connections = @intCast(config.peer.max_peers),
        }).validate();
        return .{ .transport = net, .role = config.role, .peers = try net_peer.Server.init(allocator, config.peer) };
    }

    pub fn deinit(self: *Host) void {
        self.peers.deinit();
        self.* = undefined;
    }

    pub fn poll(self: *Host) !void {
        try self.peers.poll(self.transport);
    }

    pub fn nextEvent(self: *Host) ?net_peer.Event {
        return self.peers.nextEvent();
    }
};

pub const Client = struct {
    transport: transport.Transport,
    handshake_client: handshake.Client,
    heartbeat_interval_ms: u64,
    next_sequence: u32 = 0,
    last_heartbeat_at: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator, net: transport.Transport, config: ClientConfig) !Client {
        if (config.heartbeat_interval_ms == 0) return error.InvalidSessionConfig;
        return .{ .transport = net, .handshake_client = handshake.Client.init(allocator, config.handshake), .heartbeat_interval_ms = config.heartbeat_interval_ms };
    }

    pub fn connect(self: *Client, peer: transport.Peer, nonce: u64) !void {
        self.last_heartbeat_at = null;
        try self.handshake_client.connect(peer, nonce);
    }

    pub fn poll(self: *Client) !void {
        try self.handshake_client.poll(self.transport);
        const active = self.handshake_client.session orelse return;
        const now = self.transport.now();
        if (self.last_heartbeat_at) |last| if (now < last or now - last < self.heartbeat_interval_ms) return;
        try self.send(.ping, "");
        self.last_heartbeat_at = now;
        _ = active;
    }

    pub fn connected(self: Client) bool {
        return self.handshake_client.state == .connected;
    }

    pub fn session(self: Client) !handshake.Session {
        return self.handshake_client.session orelse error.NotConnected;
    }

    pub fn sendInput(self: *Client, payload: []const u8) !void {
        try self.send(.input, payload);
    }

    pub fn disconnect(self: *Client) !void {
        try self.send(.disconnect, "");
        self.handshake_client.state = .idle;
        self.handshake_client.session = null;
        self.last_heartbeat_at = null;
    }

    fn send(self: *Client, kind: net_codec.Kind, payload: []const u8) !void {
        const active = try self.session();
        var bytes: [net_codec.header_bytes + net_codec.max_payload_bytes]u8 = undefined;
        try self.transport.send(active.peer, try net_peer.encodeSessionMessage(&bytes, kind, self.next_sequence, active.session_token, payload));
        self.next_sequence +%= 1;
    }
};

test "host and client sessions run from an explicit fixed step" {
    var client_endpoint = transport.Loopback.init(std.testing.allocator, .{ .id = 1 });
    defer client_endpoint.deinit();
    var host_endpoint = transport.Loopback.init(std.testing.allocator, .{ .id = 2 });
    defer host_endpoint.deinit();
    transport.Loopback.pair(&client_endpoint, &host_endpoint);
    var host = try Host.init(std.testing.allocator, host_endpoint.transport(), .{ .peer = .{ .heartbeat_interval_ms = 10, .timeout_ms = 50 } });
    defer host.deinit();
    var client = try Client.init(std.testing.allocator, client_endpoint.transport(), .{ .heartbeat_interval_ms = 10 });
    try std.testing.expectError(error.NotConnected, client.sendInput("before-connect"));
    try client.connect(.{ .id = 2 }, 44);

    var clock = @import("app.zig").StepClock.init(60);
    try std.testing.expectEqual(@as(u32, 1), clock.push(1.0 / 60.0));
    try client.poll();
    try host.poll();
    try client.poll();
    try std.testing.expect(client.connected());
    try client.sendInput("move");
    try host.poll();

    var joined = false;
    var input = false;
    while (host.nextEvent()) |received| {
        var event = received;
        defer event.deinit(std.testing.allocator);
        switch (event) {
            .connected => joined = true,
            .input => |value| {
                try std.testing.expectEqualStrings("move", value.message.payload[net_peer.session_token_bytes..]);
                input = true;
            },
            else => {},
        }
    }
    try std.testing.expect(joined and input);
}

test "dedicated and listen hosts run the same authoritative lifecycle" {
    for ([_]HostRole{ .dedicated, .listen }) |role| {
        var client_endpoint = transport.Loopback.init(std.testing.allocator, .{ .id = 1 });
        defer client_endpoint.deinit();
        var host_endpoint = transport.Loopback.init(std.testing.allocator, .{ .id = 2 });
        defer host_endpoint.deinit();
        transport.Loopback.pair(&client_endpoint, &host_endpoint);
        var host = try Host.init(std.testing.allocator, host_endpoint.transport(), .{ .role = role, .peer = .{ .heartbeat_interval_ms = 10, .timeout_ms = 100 } });
        defer host.deinit();
        var client = try Client.init(std.testing.allocator, client_endpoint.transport(), .{ .heartbeat_interval_ms = 10 });
        try std.testing.expectEqual(role, host.role);
        try client.connect(.{ .id = 2 }, @as(u64, @intFromEnum(role)) + 1);
        try client.poll();
        try host.poll();
        try client.poll();
        try std.testing.expect(client.connected());
        try client.sendInput("ok");
        try host.poll();
        var accepted = false;
        while (host.nextEvent()) |received| {
            var event = received;
            defer event.deinit(std.testing.allocator);
            switch (event) {
                .input => |value| accepted = std.mem.eql(u8, value.message.payload[net_peer.session_token_bytes..], "ok"),
                else => {},
            }
        }
        try std.testing.expect(accepted);
    }
}
