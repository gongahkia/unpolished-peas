const std = @import("std");
const transport = @import("minna-san-transport");
const resource = @import("resource_handle.zig");
const channel = @import("channel_registry.zig");
const delivery = @import("channel_delivery.zig");
const tcp_sessions = @import("tcp_session_registry.zig");

pub const TcpChannelRegistryError = std.mem.Allocator.Error || resource.HandleError || channel.ChannelRegistryError || delivery.ChannelDeliveryError || transport.TcpFrameError || tcp_sessions.TcpSessionRegistryError || error{ InvalidConfiguration, ChannelCapacityExceeded, UnknownSession };

pub const TcpChannelFlush = struct {
    sent: bool = false,
    pending: bool = false,
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
    pending: ?channel.QueuedMessage = null,

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
        try self.entries.append(self.allocator, .{ .session = session, .channel = handle, .storage = storage, .reader = reader, .writer = writer });
        return handle;
    }

    pub fn flush(self: *TcpChannelRegistry, session: *resource.ResourceHandle) TcpChannelRegistryError!TcpChannelFlush {
        const entry = try self.lookup(session);
        const connection = try self.sessions.connection(session);
        if (entry.pending == null) {
            entry.pending = try self.channels.dequeueExact(entry.channel);
            if (entry.pending == null) return .{};
            try entry.writer.begin(entry.pending.?.payload);
        }
        if (!try entry.writer.flush(connection)) return .{ .pending = true };
        var sent = entry.pending.?;
        sent.deinit(self.allocator);
        entry.pending = null;
        return .{ .sent = true };
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
};
