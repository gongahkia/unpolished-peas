const std = @import("std");
const routing = @import("http_service_routing.zig");
const upgrade = @import("websocket_upgrade.zig");
const websocket = @import("websocket_session.zig");

pub const HttpWebSocketGatewayError = std.mem.Allocator.Error || routing.HttpServiceRoutingError || upgrade.WebSocketUpgradeError || websocket.WebSocketSessionError || error{ InvalidConfiguration, ClientCapacityExceeded, DuplicateClient, Unauthorized };
pub const WebSocketGatewayAuthorizeFn = *const fn (?*anyopaque, upgrade.WebSocketUpgradeRequest) bool;
pub const HttpWebSocketGatewayConfig = struct {
    router: *routing.HttpServiceRouter,
    upgrade_policy: upgrade.WebSocketUpgradeConfig,
    maximum_clients: usize,
    context: ?*anyopaque = null,
    authorize: ?WebSocketGatewayAuthorizeFn = null,

    pub fn validate(self: HttpWebSocketGatewayConfig) HttpWebSocketGatewayError!void {
        if (self.maximum_clients == 0) return error.InvalidConfiguration;
        try self.upgrade_policy.validate();
    }
};
pub const GatewayBroadcast = struct { delivered: usize, backpressured: usize };

pub const HttpWebSocketGateway = struct {
    allocator: std.mem.Allocator,
    router: *routing.HttpServiceRouter,
    upgrade_policy: upgrade.WebSocketUpgradeConfig,
    capacity: usize,
    context: ?*anyopaque,
    authorize: ?WebSocketGatewayAuthorizeFn,
    clients: std.ArrayListUnmanaged(*websocket.WebSocketSession) = .empty,

    pub fn init(allocator: std.mem.Allocator, config: HttpWebSocketGatewayConfig) HttpWebSocketGatewayError!HttpWebSocketGateway {
        try config.validate();
        return .{ .allocator = allocator, .router = config.router, .upgrade_policy = config.upgrade_policy, .capacity = config.maximum_clients, .context = config.context, .authorize = config.authorize };
    }

    pub fn deinit(self: *HttpWebSocketGateway) void {
        for (self.clients.items) |client| _ = client.detach() catch continue;
        self.clients.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn dispatchHttp(self: *HttpWebSocketGateway, request: routing.HttpRouteRequest, parameters: []routing.HttpPathParameter) HttpWebSocketGatewayError!routing.HttpRouteDispatch {
        return self.router.dispatch(request, parameters);
    }

    pub fn upgradeClient(self: *HttpWebSocketGateway, request: upgrade.WebSocketUpgradeRequest, client: *websocket.WebSocketSession) HttpWebSocketGatewayError!upgrade.WebSocketUpgrade {
        if (client.state != .open) return error.InvalidConfiguration;
        if (self.authorize) |authorize| if (!authorize(self.context, request)) return error.Unauthorized;
        const response = try upgrade.validateWebSocketUpgrade(self.upgrade_policy, request);
        if (self.clients.items.len == self.capacity) return error.ClientCapacityExceeded;
        for (self.clients.items) |existing| if (existing == client) return error.DuplicateClient;
        try self.clients.append(self.allocator, client);
        return response;
    }

    pub fn broadcast(self: *HttpWebSocketGateway, payload: []const u8) GatewayBroadcast {
        var result = GatewayBroadcast{ .delivered = 0, .backpressured = 0 };
        for (self.clients.items) |client| {
            if (client.state != .open) continue;
            var delivered = true;
            client.sendMessage(payload) catch |err| switch (err) {
                error.Backpressured => {
                    result.backpressured += 1;
                    delivered = false;
                },
                else => client.beginClose(0, 1011) catch {},
            };
            if (delivered) result.delivered += 1;
        }
        return result;
    }

    pub fn detachClient(self: *HttpWebSocketGateway, client: *websocket.WebSocketSession) HttpWebSocketGatewayError!void {
        for (self.clients.items, 0..) |existing, index| {
            if (existing != client) continue;
            _ = self.clients.orderedRemove(index);
            _ = try client.detach();
            return;
        }
        return error.InvalidConfiguration;
    }
};

test "gateway upgrades an authorized route and relays bounded runtime messages" {
    const resource = @import("resource_handle.zig");
    const session = @import("session_registry.zig");
    const payload_pool = @import("payload_pool.zig");
    const channel = @import("channel_registry.zig");
    const timer = @import("timer_wheel.zig");
    const service = @import("service_module.zig");
    const Fixture = struct {
        fn route(_: ?*anyopaque, _: service.ServiceRequest) service.ServiceModuleError!service.ServiceRouteResult {
            return .handled;
        }
    };
    var resources = try resource.ResourceRegistry.init(std.testing.allocator, 4);
    defer resources.deinit();
    var sessions = try session.SessionRegistry.init(std.testing.allocator, &resources, 1);
    defer sessions.deinit();
    const owner = try sessions.create();
    try sessions.transition(owner, .begin_establishing);
    try sessions.transition(owner, .mark_ready);
    var payloads = try payload_pool.PayloadPool.init(std.testing.allocator, 2, 8);
    defer payloads.deinit();
    var channels = try channel.ChannelRegistry.init(std.testing.allocator, &resources, &sessions, &payloads, 2);
    defer channels.deinit();
    var timers = try timer.TimerWheel.init(std.testing.allocator, 2);
    defer timers.deinit();
    var client = try websocket.WebSocketSession.init(.{ .channels = &channels, .timers = &timers, .owner = owner, .maximum_message_bytes = 4, .maximum_in_flight_messages = 1, .ping_interval_ns = 10, .close_timeout_ns = 5 }, 0);
    defer client.deinit();
    var services = try service.ServiceRegistry.init(std.testing.allocator, .{ .maximum_modules = 1 });
    defer services.deinit();
    const module = try services.register(.{ .config = .{ .name = "gateway", .route_prefix = "/", .maximum_state_bytes = 1 }, .context = null, .hooks = .{ .route = Fixture.route } });
    try services.start();
    var router = try routing.HttpServiceRouter.init(std.testing.allocator, .{ .services = &services, .maximum_routes = 1 });
    defer router.deinit();
    try router.register(.{ .method = .get, .pattern = "/socket", .module = module, .maximum_body_bytes = 1 });
    var gateway = try HttpWebSocketGateway.init(std.testing.allocator, .{ .router = &router, .upgrade_policy = .{}, .maximum_clients = 1 });
    defer gateway.deinit();
    const headers = [_]@import("minna-san-protocol").HttpHeader{ .{ .name = "Upgrade", .value = "websocket" }, .{ .name = "Connection", .value = "Upgrade" }, .{ .name = "Sec-WebSocket-Version", .value = "13" }, .{ .name = "Sec-WebSocket-Key", .value = "dGhlIHNhbXBsZSBub25jZQ==" } };
    _ = try gateway.upgradeClient(.{ .method = "GET", .headers = &headers }, &client);
    try std.testing.expectEqual(@as(usize, 1), gateway.broadcast("evt").delivered);
    var message = (try client.dequeueOutbound()).?;
    defer message.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("evt", message.payload);
}
