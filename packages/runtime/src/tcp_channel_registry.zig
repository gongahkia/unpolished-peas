const std = @import("std");
const transport = @import("minna-san-transport");
const resource = @import("resource_handle.zig");
const channel = @import("channel_registry.zig");
const delivery = @import("channel_delivery.zig");
const tcp_sessions = @import("tcp_session_registry.zig");

pub const TcpChannelRegistryError = std.mem.Allocator.Error || resource.HandleError || channel.ChannelRegistryError || delivery.ChannelDeliveryError || transport.TcpFlowControlError || transport.TcpFrameError || tcp_sessions.TcpSessionRegistryError || error{ InvalidConfiguration, ChannelCapacityExceeded, UnknownSession };

pub const TcpChannelFlush = struct {
    sent: bool = false,
    pending: bool = false,
    backpressure: delivery.ChannelBackpressure = .writable,
    resumed: bool = false,
    queued_bytes: usize = 0,
};

pub const TcpChannelBackpressure = struct {
    channel: *resource.ResourceHandle,
    state: delivery.ChannelBackpressure,
    queued_bytes: usize,
    maximum_queued_bytes: usize,
    scheduler_budget: usize,
};

pub const TcpChannelReceive = struct {
    channel: *resource.ResourceHandle,
    message: channel.QueuedMessage,

    pub fn deinit(self: *TcpChannelReceive, allocator: std.mem.Allocator) void {
        self.message.deinit(allocator);
        self.* = undefined;
    }
};

const Entry = struct {
    session: *resource.ResourceHandle,
    channel: *resource.ResourceHandle,
    storage: []u8,
    reader: transport.TcpFrameReader,
    writer: transport.TcpFrameWriter,
    flow: transport.TcpFlowController,
    pending: ?channel.QueuedMessage = null,
    transport_blocked: bool = false,

    fn deinit(self: *Entry, allocator: std.mem.Allocator, channels: *channel.ChannelRegistry) void {
        if (self.pending) |*message| message.deinit(allocator);
        channels.teardown(self.channel) catch {};
        allocator.free(self.storage);
        self.* = undefined;
    }
};

pub const TcpChannelRegistry = struct {
    allocator: std.mem.Allocator,
    sessions: *tcp_sessions.TcpSessionRegistry,
    channels: *channel.ChannelRegistry,
    capacity: usize,
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator, sessions: *tcp_sessions.TcpSessionRegistry, channels: *channel.ChannelRegistry, capacity: usize) TcpChannelRegistryError!TcpChannelRegistry {
        if (capacity == 0) return error.InvalidConfiguration;
        return .{ .allocator = allocator, .sessions = sessions, .channels = channels, .capacity = capacity };
    }

    pub fn deinit(self: *TcpChannelRegistry) void {
        for (self.entries.items) |*entry| entry.deinit(self.allocator, self.channels);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn attach(self: *TcpChannelRegistry, session: *resource.ResourceHandle, descriptor: delivery.ChannelDescriptor) TcpChannelRegistryError!*resource.ResourceHandle {
        if (self.entries.items.len >= self.capacity) return error.ChannelCapacityExceeded;
        if (descriptor.transport() != .stream) return error.InvalidConfiguration;
        _ = try self.sessions.connection(session);
        const handle = try self.channels.create(session, descriptor);
        errdefer self.channels.teardown(handle) catch {};
        const storage = try self.allocator.alloc(u8, descriptor.maximum_payload_bytes);
        errdefer self.allocator.free(storage);
        const reader = try transport.TcpFrameReader.init(storage);
        const writer = try transport.TcpFrameWriter.init(descriptor.maximum_payload_bytes);
        const maximum_queued_bytes = std.math.mul(usize, descriptor.maximum_payload_bytes, descriptor.maximum_in_flight) catch return error.InvalidConfiguration;
        const flow = try transport.TcpFlowController.init(.{ .maximum_queued_bytes = maximum_queued_bytes });
        try self.entries.append(self.allocator, .{ .session = session, .channel = handle, .storage = storage, .reader = reader, .writer = writer, .flow = flow });
        return handle;
    }

    pub fn ownsChannel(self: *const TcpChannelRegistry, handle: *resource.ResourceHandle) bool {
        for (self.entries.items) |entry| if (entry.channel == handle) return true;
        return false;
    }

    pub fn enqueue(self: *TcpChannelRegistry, handle: *resource.ResourceHandle, payload: []const u8) TcpChannelRegistryError!void {
        const entry = try self.lookupChannel(handle);
        entry.flow.reserve_write(payload.len) catch |err| switch (err) {
            error.WriteQueueFull => return error.QueueFull,
            else => return err,
        };
        errdefer entry.flow.complete_write(payload.len) catch {};
        try self.channels.enqueue(handle, payload);
    }

    pub fn flush(self: *TcpChannelRegistry, session: *resource.ResourceHandle) TcpChannelRegistryError!TcpChannelFlush {
        const entry = try self.lookup(session);
        const connection = try self.sessions.connection(session);
        if (entry.pending == null) {
            entry.pending = try self.channels.dequeueExact(entry.channel);
            if (entry.pending == null) {
                const status = try self.backpressureFor(entry);
                return .{ .backpressure = status.state, .queued_bytes = status.queued_bytes };
            }
            try entry.writer.begin(entry.pending.?.payload);
        }
        if (!try entry.writer.flush(connection)) {
            entry.transport_blocked = true;
            const status = try self.backpressureFor(entry);
            return .{ .pending = true, .backpressure = status.state, .queued_bytes = status.queued_bytes };
        }
        var sent = entry.pending.?;
        const sent_bytes = sent.payload.len;
        sent.deinit(self.allocator);
        entry.pending = null;
        try entry.flow.complete_write(sent_bytes);
        const resumed = entry.transport_blocked;
        entry.transport_blocked = false;
        const status = try self.backpressureFor(entry);
        return .{ .sent = true, .backpressure = status.state, .resumed = resumed, .queued_bytes = status.queued_bytes };
    }

    pub fn backpressure(self: *TcpChannelRegistry, handle: *resource.ResourceHandle) TcpChannelRegistryError!TcpChannelBackpressure {
        return self.backpressureFor(try self.lookupChannel(handle));
    }

    pub fn receive(self: *TcpChannelRegistry, session: *resource.ResourceHandle) TcpChannelRegistryError!?TcpChannelReceive {
        const entry = try self.lookup(session);
        const connection = try self.sessions.connection(session);
        const frame = try entry.reader.read(connection) orelse return null;
        return .{ .channel = entry.channel, .message = try self.channels.copyMessage(entry.channel, frame) };
    }

    pub fn detachSession(self: *TcpChannelRegistry, session: *resource.ResourceHandle) TcpChannelRegistryError!void {
        for (self.entries.items, 0..) |entry, index| {
            if (entry.session != session) continue;
            var removed = self.entries.orderedRemove(index);
            removed.deinit(self.allocator, self.channels);
            return;
        }
    }

    fn lookup(self: *TcpChannelRegistry, session: *resource.ResourceHandle) TcpChannelRegistryError!*Entry {
        _ = try self.sessions.connection(session);
        for (self.entries.items) |*entry| if (entry.session == session) return entry;
        return error.UnknownSession;
    }

    fn lookupChannel(self: *TcpChannelRegistry, handle: *resource.ResourceHandle) TcpChannelRegistryError!*Entry {
        for (self.entries.items) |*entry| if (entry.channel == handle) return entry;
        return error.UnknownSession;
    }

    fn backpressureFor(self: *TcpChannelRegistry, entry: *Entry) TcpChannelRegistryError!TcpChannelBackpressure {
        const queued_messages = try self.channels.queued(entry.channel);
        const pending_messages: usize = if (entry.pending == null) 0 else 1;
        const state: delivery.ChannelBackpressure = if (entry.transport_blocked)
            .transport_blocked
        else if (queued_messages + pending_messages >= entry.flow.maximum_queued_bytes / entry.writer.max_message_bytes or entry.flow.available_write_bytes() == 0)
            .queue_full
        else
            .writable;
        return .{
            .channel = entry.channel,
            .state = state,
            .queued_bytes = entry.flow.queued_bytes,
            .maximum_queued_bytes = entry.flow.maximum_queued_bytes,
            .scheduler_budget = entry.flow.maximum_queued_bytes / entry.writer.max_message_bytes,
        };
    }
};

test "TCP channel registries retain bounded queued bytes while writes are blocked" {
    var resources = try resource.ResourceRegistry.init(std.testing.allocator, 2);
    defer resources.deinit();
    var sessions = try @import("session_registry.zig").SessionRegistry.init(std.testing.allocator, &resources, 1);
    defer sessions.deinit();
    var payloads = try @import("payload_pool.zig").PayloadPool.init(std.testing.allocator, 2, 16);
    defer payloads.deinit();
    var channels = try channel.ChannelRegistry.init(std.testing.allocator, &resources, &sessions, &payloads, 1);
    defer channels.deinit();
    var tcp_session_registry = try tcp_sessions.TcpSessionRegistry.init(std.testing.allocator, &sessions, 1);
    defer tcp_session_registry.deinit();
    const session = try sessions.create();
    const connection = try transport.TcpConnection.init();
    try tcp_session_registry.entries.append(std.testing.allocator, .{ .session = session, .connection = connection, .route = .{ .family = .ipv4, .address = .{ .ipv4 = transport.Ipv4Address.wildcard(1) } } });
    var registry = try TcpChannelRegistry.init(std.testing.allocator, &tcp_session_registry, &channels, 1);
    defer registry.deinit();
    const handle = try registry.attach(session, .{ .delivery = .stream, .maximum_payload_bytes = 8, .maximum_in_flight = 2 });
    try registry.enqueue(handle, "first");
    const entry = try registry.lookupChannel(handle);
    entry.pending = try channels.dequeueExact(handle);
    try entry.writer.begin(entry.pending.?.payload);
    entry.transport_blocked = true;
    try registry.enqueue(handle, "second");
    try std.testing.expectError(error.QueueFull, registry.enqueue(handle, "blocked"));
    const status = try registry.backpressure(handle);
    try std.testing.expectEqual(delivery.ChannelBackpressure.transport_blocked, status.state);
    try std.testing.expectEqual(@as(usize, 11), status.queued_bytes);
    try std.testing.expectEqual(@as(usize, 16), status.maximum_queued_bytes);
    try std.testing.expectEqual(@as(usize, 2), status.scheduler_budget);
}

test "TCP channel flushes notify resumed writes" {
    var listener = try transport.TcpListener.init(transport.Ipv4Address.wildcard(0), 1);
    defer listener.shutdown();
    const endpoint = try transport.Ipv4Address.parse("127.0.0.1", (try listener.local_address()).port);
    var client_connection = try transport.TcpConnection.init();
    _ = try client_connection.start_connect(endpoint, 1_000);
    var pending: ?transport.TcpPendingConnection = null;
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        pending = listener.accept() catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        break;
    }
    var accepted_pending = pending orelse return error.TestExpectedEqual;
    var admitted = listener.admit(&accepted_pending, .allow) orelse return error.TestExpectedEqual;
    defer admitted.connection.close();
    attempts = 0;
    while (client_connection.state == .connecting and attempts < 100) : (attempts += 1) {
        std.Thread.sleep(std.time.ns_per_ms);
        _ = try client_connection.complete(@intCast(attempts + 1));
    }
    try std.testing.expectEqual(transport.TcpConnectionState.connected, client_connection.state);

    var resources = try resource.ResourceRegistry.init(std.testing.allocator, 2);
    defer resources.deinit();
    var sessions = try @import("session_registry.zig").SessionRegistry.init(std.testing.allocator, &resources, 1);
    defer sessions.deinit();
    var payloads = try @import("payload_pool.zig").PayloadPool.init(std.testing.allocator, 1, 8);
    defer payloads.deinit();
    var channels = try channel.ChannelRegistry.init(std.testing.allocator, &resources, &sessions, &payloads, 1);
    defer channels.deinit();
    var tcp_session_registry = try tcp_sessions.TcpSessionRegistry.init(std.testing.allocator, &sessions, 1);
    defer tcp_session_registry.deinit();
    const session = try sessions.create();
    try tcp_session_registry.entries.append(std.testing.allocator, .{ .session = session, .connection = client_connection, .route = .{ .family = .ipv4, .address = .{ .ipv4 = endpoint } } });
    var registry = try TcpChannelRegistry.init(std.testing.allocator, &tcp_session_registry, &channels, 1);
    defer registry.deinit();
    const handle = try registry.attach(session, .{ .delivery = .stream, .maximum_payload_bytes = 8 });
    try registry.enqueue(handle, "resume");
    (try registry.lookupChannel(handle)).transport_blocked = true;
    const result = try registry.flush(session);
    try std.testing.expect(result.sent);
    try std.testing.expect(result.resumed);
    try std.testing.expectEqual(delivery.ChannelBackpressure.writable, result.backpressure);
    try std.testing.expectEqual(@as(usize, 0), result.queued_bytes);
}
