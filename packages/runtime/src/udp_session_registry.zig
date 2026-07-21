const std = @import("std");
const transport = @import("minna-san-transport");
const resource = @import("resource_handle.zig");
const session = @import("session_registry.zig");
const channel = @import("channel_registry.zig");
const delivery = @import("channel_delivery.zig");

pub const UdpSessionError = std.mem.Allocator.Error || resource.HandleError || session.SessionRegistryError || channel.ChannelRegistryError || transport.EndpointSelectionError || transport.SocketError || delivery.ChannelDeliveryError || error{ InvalidConfiguration, InvalidState, ConnectFailed, UnknownSession, EmptyBatch, BatchTooLarge, ReceiveFailed, DatagramTooLarge, WouldBlock };

pub const UdpDialConfig = struct {
    endpoint: transport.Endpoint,
    resolved: []const transport.ResolvedAddress = &.{},
    family_policy: transport.AddressFamilyPolicy = .prefer_ipv6,
    platform_support: transport.PlatformSupport,
    channel: delivery.ChannelDescriptor,
};

pub const UdpSessionPoll = struct {
    state: session.SessionState,
    channel: *resource.ResourceHandle,
};

pub const UdpReceiveEvent = struct {
    sequence: u64,
    session: *resource.ResourceHandle,
    channel: *resource.ResourceHandle,
    source: transport.ResolvedAddress,
    payload_len: usize,
};

pub const UdpReceiveBatch = struct {
    received: usize = 0,
    would_block: bool = false,
    backpressured: bool = false,
};

const Entry = struct {
    session: *resource.ResourceHandle,
    channel: *resource.ResourceHandle,
    socket: transport.Socket,
    route: transport.DialRoute,
};

pub const UdpSessionRegistry = struct {
    allocator: std.mem.Allocator,
    sessions: *session.SessionRegistry,
    channels: *channel.ChannelRegistry,
    capacity: usize,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    next_receive_sequence: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, sessions: *session.SessionRegistry, channels: *channel.ChannelRegistry, capacity: usize) UdpSessionError!UdpSessionRegistry {
        if (capacity == 0 or capacity > sessions.capacity) return error.InvalidConfiguration;
        return .{ .allocator = allocator, .sessions = sessions, .channels = channels, .capacity = capacity };
    }

    pub fn deinit(self: *UdpSessionRegistry) void {
        for (self.entries.items) |*entry| self.closeEntry(entry);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn dial(self: *UdpSessionRegistry, config: UdpDialConfig) UdpSessionError!*resource.ResourceHandle {
        if (self.entries.items.len >= self.capacity) return error.SessionCapacityExceeded;
        const route = try transport.select_dial_route(config.endpoint, config.resolved, config.family_policy, config.platform_support);
        const session_handle = try self.sessions.create();
        errdefer self.closeSession(session_handle);
        try self.sessions.transition(session_handle, .begin_establishing);
        const channel_handle = try self.channels.create(session_handle, config.channel);
        errdefer self.channels.teardown(channel_handle) catch {};
        var socket = try route.open(.udp);
        errdefer socket.close();
        try connect(&socket, route.address);
        try self.entries.append(self.allocator, .{ .session = session_handle, .channel = channel_handle, .socket = socket, .route = route });
        return session_handle;
    }

    pub fn poll(self: *UdpSessionRegistry, handle: *resource.ResourceHandle) UdpSessionError!UdpSessionPoll {
        const entry = try self.lookup(handle);
        const lifecycle = try self.sessions.lookup(handle);
        switch (lifecycle.state) {
            .establishing => try lifecycle.transition(.mark_ready),
            .ready => {},
            else => return error.InvalidState,
        }
        return .{ .state = lifecycle.state, .channel = entry.channel };
    }

    pub fn pollReceives(self: *UdpSessionRegistry, handle: *resource.ResourceHandle, events: []UdpReceiveEvent) UdpSessionError!UdpReceiveBatch {
        if (events.len == 0) return error.EmptyBatch;
        if (events.len > transport.max_udp_receive_batch) return error.BatchTooLarge;
        const entry = try self.lookup(handle);
        if ((try self.sessions.lookup(handle)).state != .ready) return error.InvalidState;
        var storage: [transport.max_ipv4_datagram_bytes]u8 = undefined;
        var batch = UdpReceiveBatch{};
        for (events) |*event| {
            const datagram = receive(&entry.socket, entry.route.family, storage[0..]) catch |err| switch (err) {
                error.WouldBlock => {
                    batch.would_block = true;
                    return batch;
                },
                else => return err,
            };
            self.channels.enqueue(entry.channel, datagram.bytes) catch |err| switch (err) {
                error.PayloadTooLarge => return error.DatagramTooLarge,
                else => return err,
            };
            event.* = .{ .sequence = self.next_receive_sequence, .session = handle, .channel = entry.channel, .source = datagram.source, .payload_len = datagram.bytes.len };
            self.next_receive_sequence +%= 1;
            batch.received += 1;
        }
        var descriptors = [_]std.posix.pollfd{.{ .fd = entry.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&descriptors, 0) catch return error.ReceiveFailed;
        batch.backpressured = ready != 0 and descriptors[0].revents & std.posix.POLL.IN != 0;
        return batch;
    }

    pub fn localAddress(self: *UdpSessionRegistry, handle: *resource.ResourceHandle) UdpSessionError!transport.ResolvedAddress {
        const entry = try self.lookup(handle);
        return switch (entry.route.family) {
            .ipv4 => {
                var native = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
                var length = native.getOsSockLen();
                std.posix.getsockname(entry.socket.handle, &native.any, &length) catch return error.ReceiveFailed;
                return .{ .ipv4 = transport.Ipv4Address.from_native(native) catch return error.ReceiveFailed };
            },
            .ipv6 => {
                var native = std.net.Address.initIp6(.{0} ** 16, 0, 0, 0);
                var length = native.getOsSockLen();
                std.posix.getsockname(entry.socket.handle, &native.any, &length) catch return error.ReceiveFailed;
                return .{ .ipv6 = transport.Ipv6Address.from_native(native) catch return error.ReceiveFailed };
            },
        };
    }

    pub fn close(self: *UdpSessionRegistry, handle: *resource.ResourceHandle) UdpSessionError!void {
        _ = try self.lookup(handle);
        for (self.entries.items, 0..) |_, index| {
            if (self.entries.items[index].session != handle) continue;
            var entry = self.entries.orderedRemove(index);
            self.closeEntry(&entry);
            return;
        }
        return error.UnknownSession;
    }

    fn lookup(self: *UdpSessionRegistry, handle: *resource.ResourceHandle) UdpSessionError!*Entry {
        _ = try self.sessions.lookup(handle);
        for (self.entries.items) |*entry| if (entry.session == handle) return entry;
        return error.UnknownSession;
    }

    fn closeEntry(self: *UdpSessionRegistry, entry: *Entry) void {
        entry.socket.close();
        self.channels.teardown(entry.channel) catch {};
        self.closeSession(entry.session);
    }

    fn closeSession(self: *UdpSessionRegistry, handle: *resource.ResourceHandle) void {
        const lifecycle = self.sessions.lookup(handle) catch return;
        switch (lifecycle.state) {
            .establishing, .ready => lifecycle.transition(.begin_draining) catch return,
            .draining => {},
            else => return,
        }
        self.sessions.close(handle) catch {};
    }
};

fn connect(socket: *transport.Socket, address: transport.ResolvedAddress) UdpSessionError!void {
    const native = switch (address) {
        .ipv4 => |value| value.to_native(),
        .ipv6 => |value| value.to_native(),
    };
    std.posix.connect(socket.handle, &native.any, native.getOsSockLen()) catch return error.ConnectFailed;
}

const ReceivedDatagram = struct {
    bytes: []u8,
    source: transport.ResolvedAddress,
};

fn receive(socket: *transport.Socket, family: transport.SocketAddressFamily, storage: []u8) UdpSessionError!ReceivedDatagram {
    return switch (family) {
        .ipv4 => {
            var native = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
            var length = native.getOsSockLen();
            const received = std.posix.recvfrom(socket.handle, storage, 0, &native.any, &length) catch |err| switch (err) {
                error.WouldBlock => return error.WouldBlock,
                error.MessageTooBig => return error.DatagramTooLarge,
                else => return error.ReceiveFailed,
            };
            return .{ .bytes = storage[0..received], .source = .{ .ipv4 = transport.Ipv4Address.from_native(native) catch return error.ReceiveFailed } };
        },
        .ipv6 => {
            var native = std.net.Address.initIp6(.{0} ** 16, 0, 0, 0);
            var length = native.getOsSockLen();
            const received = std.posix.recvfrom(socket.handle, storage, 0, &native.any, &length) catch |err| switch (err) {
                error.WouldBlock => return error.WouldBlock,
                error.MessageTooBig => return error.DatagramTooLarge,
                else => return error.ReceiveFailed,
            };
            return .{ .bytes = storage[0..received], .source = .{ .ipv6 = transport.Ipv6Address.from_native(native) catch return error.ReceiveFailed } };
        },
    };
}

test "UDP session registries establish selected local routes under explicit polling" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    {
        var resources = try resource.ResourceRegistry.init(allocator, 2);
        defer resources.deinit();
        var sessions = try session.SessionRegistry.init(allocator, &resources, 1);
        defer sessions.deinit();
        var payloads = try @import("payload_pool.zig").PayloadPool.init(allocator, 1, 64);
        defer payloads.deinit();
        var channels = try channel.ChannelRegistry.init(allocator, &resources, &sessions, &payloads, 1);
        defer channels.deinit();
        var udp_sessions = try UdpSessionRegistry.init(allocator, &sessions, &channels, 1);
        defer udp_sessions.deinit();
        const endpoint = transport.Endpoint.from_ipv4(transport.Ipv4Address{ .octets = .{ 127, 0, 0, 1 }, .port = 9 });
        const handle = try udp_sessions.dial(.{ .endpoint = endpoint, .family_policy = .ipv4_only, .platform_support = .{ .ipv4 = true, .ipv6 = false, .dual_stack = false }, .channel = .{ .delivery = .datagram, .maximum_payload_bytes = 64, .maximum_in_flight = 1 } });
        const result = try udp_sessions.poll(handle);
        try std.testing.expectEqual(session.SessionState.ready, result.state);
        try udp_sessions.close(handle);
        try std.testing.expectError(error.StaleHandle, sessions.lookup(handle));
    }
    try std.testing.expectEqual(std.heap.Check.ok, gpa.deinit());
}

test "UDP session receive batches preserve source metadata and pool ownership" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    {
        var resources = try resource.ResourceRegistry.init(allocator, 2);
        defer resources.deinit();
        var sessions = try session.SessionRegistry.init(allocator, &resources, 1);
        defer sessions.deinit();
        var payloads = try @import("payload_pool.zig").PayloadPool.init(allocator, 3, 64);
        defer payloads.deinit();
        var channels = try channel.ChannelRegistry.init(allocator, &resources, &sessions, &payloads, 1);
        defer channels.deinit();
        var udp_sessions = try UdpSessionRegistry.init(allocator, &sessions, &channels, 1);
        defer udp_sessions.deinit();
        var sender = try transport.UdpSocket.init(.{});
        defer sender.close();
        try sender.bind(try transport.Ipv4Address.parse("127.0.0.1", 0));
        const sender_address = local_ipv4_address(&sender);
        const handle = try udp_sessions.dial(.{ .endpoint = transport.Endpoint.from_ipv4(sender_address), .family_policy = .ipv4_only, .platform_support = .{ .ipv4 = true, .ipv6 = false, .dual_stack = false }, .channel = .{ .delivery = .datagram, .maximum_payload_bytes = 64, .maximum_in_flight = 3 } });
        _ = try udp_sessions.poll(handle);
        const destination = switch (try udp_sessions.localAddress(handle)) {
            .ipv4 => |address| address,
            .ipv6 => unreachable,
        };
        _ = try sender.send_to("one", destination);
        _ = try sender.send_to("two", destination);
        _ = try sender.send_to("three", destination);
        var events: [3]UdpReceiveEvent = undefined;
        const batch = try receive_with_retry(&udp_sessions, handle, events[0..]);
        try std.testing.expectEqual(@as(usize, 3), batch.received);
        for (events, 0..) |event, index| {
            try std.testing.expectEqual(@as(u64, @intCast(index)), event.sequence);
            try std.testing.expectEqual(handle, event.session);
            switch (event.source) {
                .ipv4 => |address| try std.testing.expectEqual(sender_address, address),
                .ipv6 => unreachable,
            }
        }
        var first = (try channels.dequeue(handle)).?;
        defer first.deinit(allocator);
        var second = (try channels.dequeue(handle)).?;
        defer second.deinit(allocator);
        var third = (try channels.dequeue(handle)).?;
        defer third.deinit(allocator);
        try std.testing.expectEqualStrings("one", first.payload);
        try std.testing.expectEqualStrings("two", second.payload);
        try std.testing.expectEqualStrings("three", third.payload);
        try udp_sessions.close(handle);
    }
    try std.testing.expectEqual(std.heap.Check.ok, gpa.deinit());
}

fn local_ipv4_address(socket: *transport.UdpSocket) transport.Ipv4Address {
    var native = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
    var length = native.getOsSockLen();
    std.posix.getsockname(socket.socket.handle, &native.any, &length) catch unreachable;
    return transport.Ipv4Address.from_native(native) catch unreachable;
}

fn receive_with_retry(registry: *UdpSessionRegistry, handle: *resource.ResourceHandle, events: []UdpReceiveEvent) UdpSessionError!UdpReceiveBatch {
    var total = UdpReceiveBatch{};
    var attempts: usize = 0;
    while (total.received < events.len and attempts < 100) : (attempts += 1) {
        const batch = try registry.pollReceives(handle, events[total.received..]);
        total.received += batch.received;
        total.backpressured = batch.backpressured;
        total.would_block = batch.would_block;
        if (batch.would_block) std.Thread.sleep(std.time.ns_per_ms);
    }
    if (total.received != events.len) return error.ReceiveFailed;
    return total;
}
