const std = @import("std");
const transport = @import("minna-san-transport");
const resource = @import("resource_handle.zig");
const session = @import("session_registry.zig");
const channel = @import("channel_registry.zig");
const delivery = @import("channel_delivery.zig");

pub const UdpSessionError = std.mem.Allocator.Error || resource.HandleError || session.SessionRegistryError || channel.ChannelRegistryError || transport.EndpointSelectionError || transport.SocketError || delivery.ChannelDeliveryError || error{ InvalidConfiguration, InvalidState, ConnectFailed, UnknownSession };

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
