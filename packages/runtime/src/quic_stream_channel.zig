const std = @import("std");
const core = @import("minna-san-core");
const resource = @import("resource_handle.zig");
const channel = @import("channel_registry.zig");
const delivery = @import("channel_delivery.zig");
const connections = @import("quic_connection_lifecycle.zig");

pub const max_quic_stream_events: usize = core.max_event_capacity;

pub const QuicStreamDirection = enum(u8) {
    bidirectional,
    unidirectional,
};

pub const QuicStreamState = enum(u8) {
    opening,
    open,
    send_closed,
    receive_closed,
    closed,
};

pub const QuicStreamProviderEventKind = enum(u8) {
    opened,
    readable,
    writable,
    peer_send_shutdown,
    peer_reset,
    peer_stop_sending,
    shutdown_complete,
};

pub const QuicStreamProviderEvent = extern struct {
    connection_id: u64,
    stream_id: u64,
    kind: u8,
    reserved: [3]u8 = [_]u8{0} ** 3,
    status: c_int = 0,

    pub fn eventKind(self: QuicStreamProviderEvent) ?QuicStreamProviderEventKind {
        if (!std.mem.allEqual(u8, self.reserved[0..], 0)) return null;
        return std.meta.intToEnum(QuicStreamProviderEventKind, self.kind) catch null;
    }
};

pub const QuicStreamCallback = *const fn (?*anyopaque, *const QuicStreamProviderEvent) callconv(.c) c_int;

pub const QuicStreamOpenOutput = extern struct {
    stream_id: u64 = 0,
    reserved: [8]u8 = [_]u8{0} ** 8,

    fn valid(self: QuicStreamOpenOutput) bool {
        return std.mem.allEqual(u8, self.reserved[0..], 0);
    }
};

pub const QuicStreamSendStatus = enum(u8) {
    sent,
    flow_controlled,
    closed,
};

pub const QuicStreamSendOutput = extern struct {
    status: u8 = @intFromEnum(QuicStreamSendStatus.sent),
    reserved: [7]u8 = [_]u8{0} ** 7,

    fn decode(self: QuicStreamSendOutput) ?QuicStreamSendStatus {
        if (!std.mem.allEqual(u8, self.reserved[0..], 0)) return null;
        return std.meta.intToEnum(QuicStreamSendStatus, self.status) catch null;
    }
};

pub const QuicStreamProviderVTable = extern struct {
    open: *const fn (?*anyopaque, u64, QuicStreamDirection, u8, ?*anyopaque, QuicStreamCallback, *QuicStreamOpenOutput) callconv(.c) c_int,
    send: *const fn (?*anyopaque, u64, u64, [*]const u8, usize, *QuicStreamSendOutput) callconv(.c) c_int,
    reset: *const fn (?*anyopaque, u64, u64, u64) callconv(.c) void,
    stop_sending: *const fn (?*anyopaque, u64, u64, u64) callconv(.c) void,
};

pub const QuicStreamChannelConfig = struct {
    maximum_streams: usize = 64,
    maximum_events: usize = 64,
    provider_capabilities: core.ProviderCapabilityDescriptor,

    pub fn validate(self: QuicStreamChannelConfig) (core.ProviderCapabilityDescriptorError || error{ InvalidConfiguration, ProviderCapabilityUnsupported })!void {
        if (self.maximum_streams == 0 or self.maximum_streams > core.max_channel_capacity or self.maximum_events == 0 or self.maximum_events > max_quic_stream_events) return error.InvalidConfiguration;
        try self.provider_capabilities.validate();
        if (!self.provider_capabilities.supports(.{ .transport_bits = core.transport_capability_bit(.quic), .delivery_bits = core.delivery_capability_bit(.streams) })) return error.ProviderCapabilityUnsupported;
    }
};

pub const QuicStreamSnapshot = struct {
    channel: *resource.ResourceHandle,
    session: *resource.ResourceHandle,
    connection_id: u64,
    stream_id: u64,
    direction: QuicStreamDirection,
    priority: u8,
    state: QuicStreamState,
    read_ready: bool,
    write_ready: bool,
    locally_reset: bool,
    stop_sending: bool,
};

pub const QuicStreamBackpressure = struct {
    channel: *resource.ResourceHandle,
    state: delivery.ChannelBackpressure,
    queued_messages: usize,
};

pub const QuicStreamPoll = struct {
    provider_events: usize = 0,
    sent: usize = 0,
    flow_controlled: usize = 0,
    closed: usize = 0,
};

pub const QuicStreamChannelError = std.mem.Allocator.Error || core.ProviderCapabilityDescriptorError || resource.HandleError || channel.ChannelRegistryError || connections.QuicConnectionLifecycleError || delivery.ChannelDeliveryError || error{ InvalidConfiguration, ProviderCapabilityUnsupported, StreamCapacityExceeded, DuplicateStreamId, UnknownStream, InvalidState, ConnectionNotReady, ProviderFailed, ProviderEventQueueFull };

const Entry = struct {
    session: *resource.ResourceHandle,
    connection_id: u64,
    channel: *resource.ResourceHandle,
    stream_id: u64,
    direction: QuicStreamDirection,
    initiated_locally: bool,
    priority: u8,
    opened: bool,
    send_open: bool,
    receive_open: bool,
    read_ready: bool = false,
    write_ready: bool = false,
    locally_reset: bool = false,
    stop_sending: bool = false,
    pending: ?channel.QueuedMessage = null,

    fn state(self: Entry) QuicStreamState {
        if (!self.opened) return .opening;
        if (!self.send_open and !self.receive_open) return .closed;
        if (!self.send_open) return .send_closed;
        if (!self.receive_open) return .receive_closed;
        return .open;
    }

    fn deinit(self: *Entry, allocator: std.mem.Allocator, channels: *channel.ChannelRegistry) void {
        if (self.pending) |*message| message.deinit(allocator);
        channels.teardown(self.channel) catch {};
        self.* = undefined;
    }
};

pub const QuicStreamChannelRegistry = struct {
    allocator: std.mem.Allocator,
    config: QuicStreamChannelConfig,
    channels: *channel.ChannelRegistry,
    connections: *connections.QuicConnectionLifecycle,
    context: ?*anyopaque,
    vtable: QuicStreamProviderVTable,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    events: []QuicStreamProviderEvent,
    event_start: usize = 0,
    event_count: usize = 0,
    event_mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, config: QuicStreamChannelConfig, channels: *channel.ChannelRegistry, lifecycle: *connections.QuicConnectionLifecycle, context: ?*anyopaque, vtable: QuicStreamProviderVTable) QuicStreamChannelError!QuicStreamChannelRegistry {
        try config.validate();
        const events = try allocator.alloc(QuicStreamProviderEvent, config.maximum_events);
        return .{ .allocator = allocator, .config = config, .channels = channels, .connections = lifecycle, .context = context, .vtable = vtable, .events = events };
    }

    pub fn deinit(self: *QuicStreamChannelRegistry) void {
        for (self.entries.items) |*entry| entry.deinit(self.allocator, self.channels);
        self.entries.deinit(self.allocator);
        self.allocator.free(self.events);
        self.* = undefined;
    }

    pub fn open(self: *QuicStreamChannelRegistry, owner: *resource.ResourceHandle, descriptor: delivery.ChannelDescriptor, direction: QuicStreamDirection) QuicStreamChannelError!*resource.ResourceHandle {
        if (self.entries.items.len == self.config.maximum_streams) return error.StreamCapacityExceeded;
        try descriptor.validate();
        if (descriptor.transport() != .stream) return error.InvalidConfiguration;
        const status = try self.connections.status(owner);
        if (status.state != .ready) return error.ConnectionNotReady;
        const connection_id = try self.connections.connectionId(owner);
        const handle = try self.channels.create(owner, descriptor);
        errdefer self.channels.teardown(handle) catch {};
        try self.entries.append(self.allocator, .{
            .session = owner,
            .connection_id = connection_id,
            .channel = handle,
            .stream_id = 0,
            .direction = direction,
            .initiated_locally = true,
            .priority = descriptor.priority,
            .opened = false,
            .send_open = true,
            .receive_open = direction == .bidirectional,
        });
        errdefer _ = self.entries.pop();
        var output = QuicStreamOpenOutput{};
        if (self.vtable.open(self.context, connection_id, direction, descriptor.priority, self, callback, &output) != @intFromEnum(core.CResult.ok) or !output.valid()) return error.ProviderFailed;
        for (self.entries.items[0 .. self.entries.items.len - 1]) |entry| if (entry.connection_id == connection_id and entry.stream_id == output.stream_id) return error.DuplicateStreamId;
        self.entries.items[self.entries.items.len - 1].stream_id = output.stream_id;
        return handle;
    }

    pub fn accept(self: *QuicStreamChannelRegistry, owner: *resource.ResourceHandle, descriptor: delivery.ChannelDescriptor, stream_id: u64, direction: QuicStreamDirection) QuicStreamChannelError!*resource.ResourceHandle {
        if (self.entries.items.len == self.config.maximum_streams) return error.StreamCapacityExceeded;
        try descriptor.validate();
        if (descriptor.transport() != .stream) return error.InvalidConfiguration;
        const status = try self.connections.status(owner);
        if (status.state != .ready) return error.ConnectionNotReady;
        const connection_id = try self.connections.connectionId(owner);
        for (self.entries.items) |entry| if (entry.connection_id == connection_id and entry.stream_id == stream_id) return error.DuplicateStreamId;
        const handle = try self.channels.create(owner, descriptor);
        errdefer self.channels.teardown(handle) catch {};
        try self.entries.append(self.allocator, .{
            .session = owner,
            .connection_id = connection_id,
            .channel = handle,
            .stream_id = stream_id,
            .direction = direction,
            .initiated_locally = false,
            .priority = descriptor.priority,
            .opened = true,
            .send_open = direction == .bidirectional,
            .receive_open = true,
            .read_ready = false,
            .write_ready = direction == .bidirectional,
        });
        return handle;
    }

    pub fn enqueue(self: *QuicStreamChannelRegistry, handle: *resource.ResourceHandle, payload: []const u8) QuicStreamChannelError!void {
        const entry = try self.lookup(handle);
        if (!entry.opened or !entry.send_open) return error.InvalidState;
        try self.channels.enqueue(handle, payload);
    }

    pub fn receive(self: *QuicStreamChannelRegistry, handle: *resource.ResourceHandle, payload: []const u8) QuicStreamChannelError!channel.QueuedMessage {
        const entry = try self.lookup(handle);
        if (!entry.opened or !entry.receive_open or !entry.read_ready) return error.InvalidState;
        return self.channels.copyMessage(handle, payload);
    }

    pub fn reset(self: *QuicStreamChannelRegistry, handle: *resource.ResourceHandle, error_code: u64) QuicStreamChannelError!void {
        const entry = try self.lookup(handle);
        if (!entry.opened or !entry.send_open) return error.InvalidState;
        self.vtable.reset(self.context, entry.connection_id, entry.stream_id, error_code);
        entry.send_open = false;
        entry.write_ready = false;
        entry.locally_reset = true;
        try self.discardOutbound(entry);
    }

    pub fn stopSending(self: *QuicStreamChannelRegistry, handle: *resource.ResourceHandle, error_code: u64) QuicStreamChannelError!void {
        const entry = try self.lookup(handle);
        if (!entry.opened or !entry.receive_open) return error.InvalidState;
        self.vtable.stop_sending(self.context, entry.connection_id, entry.stream_id, error_code);
        entry.receive_open = false;
        entry.read_ready = false;
        entry.stop_sending = true;
    }

    pub fn snapshot(self: *QuicStreamChannelRegistry, handle: *resource.ResourceHandle) QuicStreamChannelError!QuicStreamSnapshot {
        const entry = try self.lookup(handle);
        return .{ .channel = entry.channel, .session = entry.session, .connection_id = entry.connection_id, .stream_id = entry.stream_id, .direction = entry.direction, .priority = entry.priority, .state = entry.state(), .read_ready = entry.read_ready, .write_ready = entry.write_ready, .locally_reset = entry.locally_reset, .stop_sending = entry.stop_sending };
    }

    pub fn backpressure(self: *QuicStreamChannelRegistry, handle: *resource.ResourceHandle) QuicStreamChannelError!QuicStreamBackpressure {
        const entry = try self.lookup(handle);
        const queued = try self.channels.queued(handle);
        const state: delivery.ChannelBackpressure = if (!entry.opened or !entry.send_open)
            .closed
        else if (!entry.write_ready)
            .transport_blocked
        else if (queued + (if (entry.pending == null) @as(usize, 0) else 1) >= try self.channels.maximumInFlight(handle))
            .queue_full
        else
            .writable;
        return .{ .channel = handle, .state = state, .queued_messages = queued + if (entry.pending == null) @as(usize, 0) else 1 };
    }

    pub fn poll(self: *QuicStreamChannelRegistry, work_budget: usize) QuicStreamChannelError!QuicStreamPoll {
        if (work_budget == 0) return error.InvalidConfiguration;
        var result = QuicStreamPoll{};
        var remaining = work_budget;
        while (remaining != 0) {
            const event = self.nextEvent() orelse break;
            try self.applyEvent(event);
            result.provider_events += 1;
            remaining -= 1;
        }
        while (remaining != 0) {
            const index = self.nextWritableIndex() orelse break;
            const entry = &self.entries.items[index];
            if (entry.pending == null) entry.pending = try self.channels.dequeueExact(entry.channel);
            if (entry.pending == null) break;
            var output = QuicStreamSendOutput{};
            if (self.vtable.send(self.context, entry.connection_id, entry.stream_id, entry.pending.?.payload.ptr, entry.pending.?.payload.len, &output) != @intFromEnum(core.CResult.ok)) return error.ProviderFailed;
            switch (output.decode() orelse return error.ProviderFailed) {
                .sent => {
                    var message = entry.pending.?;
                    message.deinit(self.allocator);
                    entry.pending = null;
                    result.sent += 1;
                },
                .flow_controlled => {
                    entry.write_ready = false;
                    result.flow_controlled += 1;
                },
                .closed => {
                    entry.send_open = false;
                    entry.write_ready = false;
                    try self.discardOutbound(entry);
                    result.closed += 1;
                },
            }
            remaining -= 1;
        }
        return result;
    }

    fn callback(context: ?*anyopaque, event: *const QuicStreamProviderEvent) callconv(.c) c_int {
        const self: *QuicStreamChannelRegistry = @ptrCast(@alignCast(context orelse return @intFromEnum(core.CResult.invalid_argument)));
        if (event.eventKind() == null) return @intFromEnum(core.CResult.invalid_argument);
        self.event_mutex.lock();
        defer self.event_mutex.unlock();
        if (self.event_count == self.config.maximum_events) return @intFromEnum(core.CResult.resource_exhausted);
        const index = (self.event_start + self.event_count) % self.config.maximum_events;
        self.events[index] = event.*;
        self.event_count += 1;
        return @intFromEnum(core.CResult.ok);
    }

    fn nextEvent(self: *QuicStreamChannelRegistry) ?QuicStreamProviderEvent {
        self.event_mutex.lock();
        defer self.event_mutex.unlock();
        if (self.event_count == 0) return null;
        const event = self.events[self.event_start];
        self.event_start = (self.event_start + 1) % self.config.maximum_events;
        self.event_count -= 1;
        return event;
    }

    fn applyEvent(self: *QuicStreamChannelRegistry, event: QuicStreamProviderEvent) QuicStreamChannelError!void {
        const entry = self.lookupConnectionStream(event.connection_id, event.stream_id) orelse return error.UnknownStream;
        switch (event.eventKind().?) {
            .opened => entry.opened = true,
            .readable => {
                if (entry.receive_open) entry.read_ready = true;
            },
            .writable => {
                if (entry.send_open) entry.write_ready = true;
            },
            .peer_send_shutdown, .peer_reset => {
                entry.receive_open = false;
                entry.read_ready = false;
            },
            .peer_stop_sending => {
                entry.send_open = false;
                entry.write_ready = false;
                try self.discardOutbound(entry);
            },
            .shutdown_complete => {
                entry.send_open = false;
                entry.receive_open = false;
                entry.write_ready = false;
                entry.read_ready = false;
                try self.discardOutbound(entry);
            },
        }
    }

    fn lookup(self: *QuicStreamChannelRegistry, handle: *resource.ResourceHandle) QuicStreamChannelError!*Entry {
        for (self.entries.items) |*entry| if (entry.channel == handle) return entry;
        return error.UnknownStream;
    }

    fn lookupConnectionStream(self: *QuicStreamChannelRegistry, connection_id: u64, stream_id: u64) ?*Entry {
        for (self.entries.items) |*entry| if (entry.connection_id == connection_id and entry.stream_id == stream_id) return entry;
        return null;
    }

    fn discardOutbound(self: *QuicStreamChannelRegistry, entry: *Entry) QuicStreamChannelError!void {
        if (entry.pending) |*message| message.deinit(self.allocator);
        entry.pending = null;
        while (try self.channels.dequeueExact(entry.channel)) |message_value| {
            var message = message_value;
            message.deinit(self.allocator);
        }
    }

    fn nextWritableIndex(self: *QuicStreamChannelRegistry) ?usize {
        var selected: ?usize = null;
        for (self.entries.items, 0..) |entry, index| {
            if (!entry.opened or !entry.send_open or !entry.write_ready) continue;
            if (entry.pending == null and (self.channels.queued(entry.channel) catch 0) == 0) continue;
            if (selected == null or entry.priority > self.entries.items[selected.?].priority) selected = index;
        }
        return selected;
    }
};

test "QUIC stream channels progress independent writable streams through another stream's flow control" {
    const ConnectionProvider = struct {
        callback_context: ?*anyopaque = null,
        callback_fn: ?connections.QuicConnectionCallback = null,

        fn open(context: ?*anyopaque, connection_id: u64, _: connections.QuicConnectionRole, callback_context: ?*anyopaque, callback_fn: connections.QuicConnectionCallback) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.callback_context = callback_context;
            self.callback_fn = callback_fn;
            const event = connections.QuicConnectionProviderEvent{ .connection_id = connection_id, .kind = @intFromEnum(connections.QuicConnectionEventKind.connected) };
            return callback_fn(callback_context, &event);
        }

        fn shutdown(_: ?*anyopaque, _: u64) callconv(.c) void {}
    };
    const StreamProvider = struct {
        callback_context: ?*anyopaque = null,
        callback_fn: ?QuicStreamCallback = null,
        next_stream_id: u64 = 4,
        blocked_stream: ?u64 = null,
        sent_streams: [4]u64 = [_]u64{0} ** 4,
        sent_count: usize = 0,
        resets: usize = 0,
        stops: usize = 0,

        fn open(context: ?*anyopaque, connection_id: u64, _: QuicStreamDirection, _: u8, callback_context: ?*anyopaque, callback_fn: QuicStreamCallback, output: *QuicStreamOpenOutput) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.callback_context = callback_context;
            self.callback_fn = callback_fn;
            output.* = .{ .stream_id = self.next_stream_id };
            self.next_stream_id += 4;
            const event = QuicStreamProviderEvent{ .connection_id = connection_id, .stream_id = output.stream_id, .kind = @intFromEnum(QuicStreamProviderEventKind.opened) };
            return callback_fn(callback_context, &event);
        }

        fn send(context: ?*anyopaque, _: u64, stream_id: u64, _: [*]const u8, _: usize, output: *QuicStreamSendOutput) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.sent_streams[self.sent_count] = stream_id;
            self.sent_count += 1;
            output.* = .{ .status = @intFromEnum(if (self.blocked_stream == stream_id) QuicStreamSendStatus.flow_controlled else QuicStreamSendStatus.sent) };
            return @intFromEnum(core.CResult.ok);
        }

        fn reset(context: ?*anyopaque, _: u64, _: u64, _: u64) callconv(.c) void {
            @as(*@This(), @ptrCast(@alignCast(context.?))).resets += 1;
        }

        fn stop(context: ?*anyopaque, _: u64, _: u64, _: u64) callconv(.c) void {
            @as(*@This(), @ptrCast(@alignCast(context.?))).stops += 1;
        }

        fn emit(self: *@This(), connection_id: u64, stream_id: u64, kind: QuicStreamProviderEventKind) c_int {
            const event = QuicStreamProviderEvent{ .connection_id = connection_id, .stream_id = stream_id, .kind = @intFromEnum(kind) };
            return self.callback_fn.?(self.callback_context, &event);
        }
    };

    var resources = try resource.ResourceRegistry.init(std.testing.allocator, 4);
    defer resources.deinit();
    var sessions = try @import("session_registry.zig").SessionRegistry.init(std.testing.allocator, &resources, 1);
    defer sessions.deinit();
    var connection_provider = ConnectionProvider{};
    var lifecycle = try connections.QuicConnectionLifecycle.init(std.testing.allocator, &sessions, .{ .maximum_connections = 1, .maximum_events = 4 }, &connection_provider, .{ .open = ConnectionProvider.open, .shutdown = ConnectionProvider.shutdown });
    defer lifecycle.deinit();
    const owner = try lifecycle.connect(.{ .role = .client }, 0);
    _ = try lifecycle.poll(0, 1);
    var payloads = try @import("payload_pool.zig").PayloadPool.init(std.testing.allocator, 4, 32);
    defer payloads.deinit();
    var channels = try channel.ChannelRegistry.init(std.testing.allocator, &resources, &sessions, &payloads, 3);
    defer channels.deinit();
    var stream_provider = StreamProvider{};
    var registry = try QuicStreamChannelRegistry.init(std.testing.allocator, .{ .maximum_streams = 3, .maximum_events = 8, .provider_capabilities = .{ .transport_bits = core.transport_capability_bit(.quic), .delivery_bits = core.delivery_capability_bit(.streams) } }, &channels, &lifecycle, &stream_provider, .{ .open = StreamProvider.open, .send = StreamProvider.send, .reset = StreamProvider.reset, .stop_sending = StreamProvider.stop });
    defer registry.deinit();

    const high = try registry.open(owner, .{ .delivery = .ordered, .priority = 255, .maximum_payload_bytes = 8, .maximum_in_flight = 2 }, .bidirectional);
    const low = try registry.open(owner, .{ .delivery = .ordered, .priority = 1, .maximum_payload_bytes = 8, .maximum_in_flight = 2 }, .bidirectional);
    _ = try registry.poll(2);
    const high_id = (try registry.snapshot(high)).stream_id;
    const low_id = (try registry.snapshot(low)).stream_id;
    try std.testing.expectEqual(@intFromEnum(core.CResult.ok), stream_provider.emit((try lifecycle.connectionId(owner)), high_id, .writable));
    try std.testing.expectEqual(@intFromEnum(core.CResult.ok), stream_provider.emit((try lifecycle.connectionId(owner)), low_id, .writable));
    stream_provider.blocked_stream = high_id;
    try registry.enqueue(high, "high");
    try registry.enqueue(low, "low");
    const first = try registry.poll(4);
    try std.testing.expectEqual(@as(usize, 1), first.flow_controlled);
    try std.testing.expectEqual(@as(usize, 1), first.sent);
    try std.testing.expectEqual(high_id, stream_provider.sent_streams[0]);
    try std.testing.expectEqual(low_id, stream_provider.sent_streams[1]);
    try std.testing.expectEqual(delivery.ChannelBackpressure.transport_blocked, (try registry.backpressure(high)).state);
    stream_provider.blocked_stream = null;
    try std.testing.expectEqual(@intFromEnum(core.CResult.ok), stream_provider.emit((try lifecycle.connectionId(owner)), high_id, .writable));
    try std.testing.expectEqual(@as(usize, 1), (try registry.poll(2)).sent);
    try registry.reset(high, 7);
    try registry.stopSending(high, 7);
    try std.testing.expectEqual(@as(usize, 1), stream_provider.resets);
    try std.testing.expectEqual(@as(usize, 1), stream_provider.stops);
    try std.testing.expectEqual(QuicStreamState.closed, (try registry.snapshot(high)).state);

    const incoming = try registry.accept(owner, .{ .delivery = .stream, .maximum_payload_bytes = 8 }, 24, .unidirectional);
    try std.testing.expectError(error.InvalidState, registry.receive(incoming, "peer"));
    try std.testing.expectEqual(@intFromEnum(core.CResult.ok), stream_provider.emit((try lifecycle.connectionId(owner)), 24, .readable));
    _ = try registry.poll(1);
    var received = try registry.receive(incoming, "peer");
    defer received.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("peer", received.payload);
    try std.testing.expectError(error.InvalidState, registry.enqueue(incoming, "nope"));
}
