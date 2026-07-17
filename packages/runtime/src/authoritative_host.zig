const std = @import("std");
const core = @import("minna-san-core");
const protocol = @import("minna-san-protocol");

pub const HostPeerId = u64;
pub const HostChannelId = u64;
pub const SessionOwner = union(enum) {
    dedicated,
    listen: HostPeerId,
};
pub const RouteDirection = enum { inbound, outbound };
pub const AuthoritativeHostError = std.mem.Allocator.Error || core.ClockError || error{ InvalidConfiguration, LocalPeerConflict, PeerAlreadyConnected, PeerCapacityExceeded, UnknownPeer, ChannelAlreadyOpen, ChannelCapacityExceeded, UnknownChannel, TickOverflow };

pub const AuthoritativeHostConfig = struct {
    owner: SessionOwner,
    clock: core.Clock,
    maximum_peers: usize,
    maximum_channels_per_peer: usize,
    tick_interval_ns: core.TimeNs,
    maximum_ticks_per_pump: usize = 1,
};

pub const HostTick = struct {
    first_index: u64,
    count: u64,
    scheduled_at_ns: core.TimeNs,
};

pub const RoutedHostMessage = struct {
    peer: HostPeerId,
    channel: HostChannelId,
    capability: protocol.ChannelCapability,
    direction: RouteDirection,
    payload: []const u8,
};

const HostChannel = struct {
    id: HostChannelId,
    capability: protocol.ChannelCapability,
    inbound_messages: u64 = 0,
    outbound_messages: u64 = 0,
};

const HostPeer = struct {
    id: HostPeerId,
    channels: std.ArrayListUnmanaged(HostChannel) = .empty,

    fn deinit(self: *HostPeer, allocator: std.mem.Allocator) void {
        self.channels.deinit(allocator);
        self.* = undefined;
    }
};

pub const AuthoritativeHost = struct {
    allocator: std.mem.Allocator,
    config: AuthoritativeHostConfig,
    clock: core.CheckedClock,
    peers: std.ArrayListUnmanaged(HostPeer) = .empty,
    next_tick_ns: ?core.TimeNs = null,
    next_tick_index: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, config: AuthoritativeHostConfig) AuthoritativeHostError!AuthoritativeHost {
        if (config.maximum_peers == 0 or config.maximum_channels_per_peer == 0 or config.tick_interval_ns == 0 or config.maximum_ticks_per_pump == 0) return error.InvalidConfiguration;
        switch (config.owner) {
            .dedicated => {},
            .listen => |peer| if (peer == 0) return error.InvalidConfiguration,
        }
        return .{ .allocator = allocator, .config = config, .clock = .init(config.clock) };
    }

    pub fn deinit(self: *AuthoritativeHost) void {
        for (self.peers.items) |*peer| peer.deinit(self.allocator);
        self.peers.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn session_owner(self: AuthoritativeHost) SessionOwner {
        return self.config.owner;
    }

    pub fn peer_count(self: AuthoritativeHost) usize {
        return self.peers.items.len;
    }

    pub fn connect_peer(self: *AuthoritativeHost, peer: HostPeerId) AuthoritativeHostError!void {
        if (peer == 0) return error.InvalidConfiguration;
        if (self.config.owner == .listen and peer == self.config.owner.listen) return error.LocalPeerConflict;
        if (self.peer_ptr(peer) != null) return error.PeerAlreadyConnected;
        if (self.peers.items.len == self.config.maximum_peers) return error.PeerCapacityExceeded;
        try self.peers.append(self.allocator, .{ .id = peer });
    }

    pub fn disconnect_peer(self: *AuthoritativeHost, peer: HostPeerId) AuthoritativeHostError!void {
        for (self.peers.items, 0..) |_, index| {
            if (self.peers.items[index].id != peer) continue;
            self.peers.items[index].deinit(self.allocator);
            for (self.peers.items[index + 1 ..], index..) |next, destination| self.peers.items[destination] = next;
            self.peers.items.len -= 1;
            return;
        }
        return error.UnknownPeer;
    }

    pub fn open_channel(self: *AuthoritativeHost, peer: HostPeerId, channel: HostChannelId, capability: protocol.ChannelCapability) AuthoritativeHostError!void {
        if (channel == 0) return error.InvalidConfiguration;
        const host_peer = self.peer_ptr(peer) orelse return error.UnknownPeer;
        for (host_peer.channels.items) |existing| if (existing.id == channel) return error.ChannelAlreadyOpen;
        if (host_peer.channels.items.len == self.config.maximum_channels_per_peer) return error.ChannelCapacityExceeded;
        try host_peer.channels.append(self.allocator, .{ .id = channel, .capability = capability });
    }

    pub fn close_channel(self: *AuthoritativeHost, peer: HostPeerId, channel: HostChannelId) AuthoritativeHostError!void {
        const host_peer = self.peer_ptr(peer) orelse return error.UnknownPeer;
        for (host_peer.channels.items, 0..) |existing, index| {
            if (existing.id != channel) continue;
            for (host_peer.channels.items[index + 1 ..], index..) |next, destination| host_peer.channels.items[destination] = next;
            host_peer.channels.items.len -= 1;
            return;
        }
        return error.UnknownChannel;
    }

    pub fn route(self: *AuthoritativeHost, peer: HostPeerId, channel: HostChannelId, direction: RouteDirection, payload: []const u8) AuthoritativeHostError!RoutedHostMessage {
        const host_peer = self.peer_ptr(peer) orelse return error.UnknownPeer;
        const host_channel = channel_ptr(host_peer, channel) orelse return error.UnknownChannel;
        switch (direction) {
            .inbound => host_channel.inbound_messages +%= 1,
            .outbound => host_channel.outbound_messages +%= 1,
        }
        return .{ .peer = peer, .channel = channel, .capability = host_channel.capability, .direction = direction, .payload = payload };
    }

    pub fn tick(self: *AuthoritativeHost) AuthoritativeHostError!?HostTick {
        const now_ns = try self.clock.now();
        if (self.next_tick_ns == null) self.next_tick_ns = now_ns;
        const scheduled_at_ns = self.next_tick_ns.?;
        if (now_ns < scheduled_at_ns) return null;
        const elapsed = now_ns - scheduled_at_ns;
        const due = elapsed / self.config.tick_interval_ns +| 1;
        const count = @min(due, @as(u64, @intCast(self.config.maximum_ticks_per_pump)));
        const interval = std.math.mul(core.TimeNs, self.config.tick_interval_ns, count) catch return error.TickOverflow;
        self.next_tick_ns = std.math.add(core.TimeNs, scheduled_at_ns, interval) catch return error.TickOverflow;
        const first_index = self.next_tick_index;
        self.next_tick_index = std.math.add(u64, self.next_tick_index, count) catch return error.TickOverflow;
        return .{ .first_index = first_index, .count = count, .scheduled_at_ns = scheduled_at_ns };
    }

    fn peer_ptr(self: *AuthoritativeHost, peer: HostPeerId) ?*HostPeer {
        for (self.peers.items) |*candidate| if (candidate.id == peer) return candidate;
        return null;
    }
};

fn channel_ptr(peer: *HostPeer, channel: HostChannelId) ?*HostChannel {
    for (peer.channels.items) |*candidate| if (candidate.id == channel) return candidate;
    return null;
}

test "dedicated hosts own bounded peer lifecycle channel routing and ticks" {
    var manual = core.ManualClock.init(0);
    var host = try AuthoritativeHost.init(std.testing.allocator, .{
        .owner = .dedicated,
        .clock = manual.clock(),
        .maximum_peers = 1,
        .maximum_channels_per_peer = 1,
        .tick_interval_ns = 10,
        .maximum_ticks_per_pump = 2,
    });
    defer host.deinit();
    try std.testing.expectEqual(SessionOwner.dedicated, host.session_owner());
    try std.testing.expectEqual(HostTick{ .first_index = 0, .count = 1, .scheduled_at_ns = 0 }, (try host.tick()).?);
    try manual.advance(9);
    try std.testing.expect((try host.tick()) == null);
    try manual.advance(11);
    try std.testing.expectEqual(HostTick{ .first_index = 1, .count = 2, .scheduled_at_ns = 10 }, (try host.tick()).?);
    try host.connect_peer(7);
    try std.testing.expectEqual(@as(usize, 1), host.peer_count());
    try host.open_channel(7, 1, .reliable);
    const routed = try host.route(7, 1, .inbound, "input");
    try std.testing.expectEqual(protocol.ChannelCapability.reliable, routed.capability);
    try std.testing.expectEqualStrings("input", routed.payload);
    try std.testing.expectError(error.ChannelAlreadyOpen, host.open_channel(7, 1, .reliable));
    try std.testing.expectError(error.ChannelCapacityExceeded, host.open_channel(7, 2, .unreliable));
    try host.disconnect_peer(7);
    try std.testing.expectError(error.UnknownPeer, host.route(7, 1, .outbound, "state"));
}

test "listen hosts reserve their local owner identity and validate capacity" {
    var manual = core.ManualClock.init(1);
    var host = try AuthoritativeHost.init(std.testing.allocator, .{
        .owner = .{ .listen = 1 },
        .clock = manual.clock(),
        .maximum_peers = 1,
        .maximum_channels_per_peer = 1,
        .tick_interval_ns = 1,
    });
    defer host.deinit();
    try std.testing.expectEqual(SessionOwner{ .listen = 1 }, host.session_owner());
    try std.testing.expectError(error.LocalPeerConflict, host.connect_peer(1));
    try host.connect_peer(2);
    try std.testing.expectError(error.PeerCapacityExceeded, host.connect_peer(3));
    try std.testing.expectError(error.UnknownChannel, host.route(2, 1, .inbound, "missing"));
    try std.testing.expectError(error.InvalidConfiguration, AuthoritativeHost.init(std.testing.allocator, .{
        .owner = .{ .listen = 0 },
        .clock = manual.clock(),
        .maximum_peers = 1,
        .maximum_channels_per_peer = 1,
        .tick_interval_ns = 1,
    }));
}
