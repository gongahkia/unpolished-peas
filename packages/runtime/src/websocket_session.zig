const std = @import("std");
const core = @import("minna-san-core");
const resource = @import("resource_handle.zig");
const channel = @import("channel_registry.zig");
const delivery = @import("channel_delivery.zig");
const timer_wheel = @import("timer_wheel.zig");

pub const WebSocketSessionError = channel.ChannelRegistryError || timer_wheel.TimerWheelError || error{ InvalidConfiguration, InvalidState, Backpressured, MessageTooLarge };
pub const WebSocketSessionState = enum { open, closing, closed, detached };
pub const WebSocketSessionEvent = union(enum) { ping_due: void, close_started: u16, close_reply: u16, closed: u16, detached: void };
pub const WebSocketSessionConfig = struct {
    channels: *channel.ChannelRegistry,
    timers: *timer_wheel.TimerWheel,
    owner: *resource.ResourceHandle,
    maximum_message_bytes: usize,
    maximum_in_flight_messages: usize,
    ping_interval_ns: core.TimeNs,
    close_timeout_ns: core.TimeNs,

    pub fn validate(self: WebSocketSessionConfig) WebSocketSessionError!void {
        if (self.maximum_message_bytes == 0 or self.maximum_in_flight_messages == 0 or self.ping_interval_ns == 0 or self.close_timeout_ns == 0) return error.InvalidConfiguration;
    }
};

pub const WebSocketSession = struct {
    channels: *channel.ChannelRegistry,
    timers: *timer_wheel.TimerWheel,
    inbound: *resource.ResourceHandle,
    outbound: *resource.ResourceHandle,
    maximum_message_bytes: usize,
    ping_interval_ns: core.TimeNs,
    close_timeout_ns: core.TimeNs,
    deadline: ?timer_wheel.TimerId = null,
    state: WebSocketSessionState = .open,

    pub fn init(config: WebSocketSessionConfig, now_ns: core.TimeNs) WebSocketSessionError!WebSocketSession {
        try config.validate();
        const descriptor = delivery.ChannelDescriptor{ .delivery = .stream, .maximum_payload_bytes = config.maximum_message_bytes, .maximum_in_flight = config.maximum_in_flight_messages };
        const inbound = try config.channels.create(config.owner, descriptor);
        errdefer config.channels.teardown(inbound) catch {};
        const outbound = try config.channels.create(config.owner, descriptor);
        errdefer config.channels.teardown(outbound) catch {};
        const deadline = try config.timers.schedule(.keepalive, std.math.add(core.TimeNs, now_ns, config.ping_interval_ns) catch return error.InvalidConfiguration);
        return .{ .channels = config.channels, .timers = config.timers, .inbound = inbound, .outbound = outbound, .maximum_message_bytes = config.maximum_message_bytes, .ping_interval_ns = config.ping_interval_ns, .close_timeout_ns = config.close_timeout_ns, .deadline = deadline };
    }

    pub fn deinit(self: *WebSocketSession) void {
        _ = self.detach() catch {};
        self.* = undefined;
    }

    pub fn receiveMessage(self: *WebSocketSession, payload: []const u8) WebSocketSessionError!void {
        if (self.state != .open) return error.InvalidState;
        if (payload.len > self.maximum_message_bytes) return error.MessageTooLarge;
        self.channels.enqueue(self.inbound, payload) catch |err| switch (err) {
            error.QueueFull => return error.Backpressured,
            else => return err,
        };
    }

    pub fn sendMessage(self: *WebSocketSession, payload: []const u8) WebSocketSessionError!void {
        if (self.state != .open) return error.InvalidState;
        if (payload.len > self.maximum_message_bytes) return error.MessageTooLarge;
        self.channels.enqueue(self.outbound, payload) catch |err| switch (err) {
            error.QueueFull => return error.Backpressured,
            else => return err,
        };
    }

    pub fn dequeueInbound(self: *WebSocketSession) WebSocketSessionError!?channel.QueuedMessage {
        return self.channels.dequeueExact(self.inbound);
    }
    pub fn dequeueOutbound(self: *WebSocketSession) WebSocketSessionError!?channel.QueuedMessage {
        return self.channels.dequeueExact(self.outbound);
    }

    pub fn beginClose(self: *WebSocketSession, now_ns: core.TimeNs, code: u16) WebSocketSessionError!WebSocketSessionEvent {
        if (self.state != .open) return error.InvalidState;
        self.cancelDeadline();
        self.deadline = try self.timers.schedule(.session, std.math.add(core.TimeNs, now_ns, self.close_timeout_ns) catch return error.InvalidConfiguration);
        self.state = .closing;
        return .{ .close_started = code };
    }

    pub fn receiveClose(self: *WebSocketSession, code: u16) WebSocketSessionError!WebSocketSessionEvent {
        if (self.state == .detached or self.state == .closed) return error.InvalidState;
        if (self.state == .open) {
            self.state = .closing;
            return .{ .close_reply = code };
        }
        self.cancelDeadline();
        self.state = .closed;
        return .{ .closed = code };
    }

    pub fn onTimer(self: *WebSocketSession, timer: timer_wheel.Timer, now_ns: core.TimeNs) WebSocketSessionError!?WebSocketSessionEvent {
        if (self.deadline == null or timer.id != self.deadline.?) return null;
        self.deadline = null;
        return switch (self.state) {
            .open => blk: {
                self.deadline = try self.timers.schedule(.keepalive, std.math.add(core.TimeNs, now_ns, self.ping_interval_ns) catch return error.InvalidConfiguration);
                break :blk .{ .ping_due = {} };
            },
            .closing => blk: {
                self.state = .closed;
                break :blk .{ .closed = 1006 };
            },
            else => null,
        };
    }

    pub fn detach(self: *WebSocketSession) WebSocketSessionError!WebSocketSessionEvent {
        if (self.state == .detached) return error.InvalidState;
        self.cancelDeadline();
        self.channels.teardown(self.inbound) catch |err| if (err != error.UnknownChannel) return err;
        self.channels.teardown(self.outbound) catch |err| if (err != error.UnknownChannel) return err;
        self.state = .detached;
        return .{ .detached = {} };
    }

    fn cancelDeadline(self: *WebSocketSession) void {
        if (self.deadline) |id| self.timers.cancel(id) catch {};
        self.deadline = null;
    }
};

test "slow WebSocket receivers backpressure queues and finish a clean close handshake" {
    const session = @import("session_registry.zig");
    const payload_pool = @import("payload_pool.zig");
    var resources = try resource.ResourceRegistry.init(std.testing.allocator, 3);
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
    var timers = try timer_wheel.TimerWheel.init(std.testing.allocator, 2);
    defer timers.deinit();
    var websocket = try WebSocketSession.init(.{ .channels = &channels, .timers = &timers, .owner = owner, .maximum_message_bytes = 4, .maximum_in_flight_messages = 1, .ping_interval_ns = 10, .close_timeout_ns = 5 }, 0);
    defer websocket.deinit();
    try websocket.receiveMessage("one");
    try std.testing.expectError(error.Backpressured, websocket.receiveMessage("two"));
    var message = (try websocket.dequeueInbound()).?;
    message.deinit(std.testing.allocator);
    try websocket.receiveMessage("two");
    _ = try websocket.beginClose(1, 1000);
    try std.testing.expect((try websocket.receiveClose(1000)) == .closed);
    try std.testing.expectEqual(WebSocketSessionState.closed, websocket.state);
}
