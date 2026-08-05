const std = @import("std");
const core = @import("minna-san-core");
const protocol = @import("minna-san-protocol");
const permissions = @import("turn_permissions.zig");
const channels = @import("turn_channels.zig");

pub const TurnPermissionChannelLifecycleError = permissions.TurnPermissionError || channels.TurnChannelError || error{ Closed, UnauthorizedPeer, ChannelUnavailable };
pub const TurnPermissionChannelLifecycleConfig = struct {
    maximum_permissions: usize,
    permission_lifetime_ns: core.TimeNs,
    maximum_channels: usize,
};
pub const TurnRelayedChannelData = struct { peer: protocol.StunAddress, payload: []const u8 };

pub const TurnPermissionChannelLifecycle = struct {
    permissions: permissions.TurnPermissions,
    channels: channels.TurnChannels,
    next_channel: u16 = channels.turn_channel_min,
    closed: bool = false,

    pub fn init(allocator: std.mem.Allocator, config: TurnPermissionChannelLifecycleConfig) TurnPermissionChannelLifecycleError!TurnPermissionChannelLifecycle {
        if (config.maximum_channels == 0 or config.maximum_channels > @as(usize, channels.turn_channel_max - channels.turn_channel_min + 1)) return error.InvalidConfiguration;
        var permission_table = try permissions.TurnPermissions.init(allocator, .{ .maximum_permissions = config.maximum_permissions, .lifetime_ns = config.permission_lifetime_ns });
        errdefer permission_table.deinit();
        const channel_table = try channels.TurnChannels.init(allocator, .{ .maximum_channels = config.maximum_channels });
        return .{ .permissions = permission_table, .channels = channel_table };
    }

    pub fn deinit(self: *TurnPermissionChannelLifecycle) void {
        self.permissions.deinit();
        self.channels.deinit();
        self.* = undefined;
    }

    pub fn authorize_peer(self: *TurnPermissionChannelLifecycle, peer: protocol.StunAddress, now_ns: core.TimeNs) TurnPermissionChannelLifecycleError!permissions.TurnPermission {
        try self.requireActive();
        return self.permissions.authorize(peer, now_ns);
    }

    pub fn renew_permission(self: *TurnPermissionChannelLifecycle, peer: protocol.StunAddress, now_ns: core.TimeNs) TurnPermissionChannelLifecycleError!permissions.TurnPermission {
        try self.requireActive();
        return self.permissions.refresh(peer, now_ns) catch |err| {
            if (err == error.PermissionExpired or err == error.UnauthorizedPeer) _ = self.channels.unbind_peer(peer);
            return err;
        };
    }

    pub fn assign_channel(self: *TurnPermissionChannelLifecycle, peer: protocol.StunAddress, requested: ?u16, now_ns: core.TimeNs) TurnPermissionChannelLifecycleError!channels.TurnChannelBinding {
        try self.requireActive();
        if (!self.permissions.authorized(peer, now_ns)) {
            _ = self.channels.unbind_peer(peer);
            return error.UnauthorizedPeer;
        }
        const number = requested orelse try self.nextAvailableChannel();
        try self.channels.bind(.{ .number = number, .peer = peer });
        self.next_channel = if (number == channels.turn_channel_max) channels.turn_channel_min else number + 1;
        return self.channels.binding(number) orelse error.ChannelUnavailable;
    }

    pub fn receive_channel(self: *TurnPermissionChannelLifecycle, input: []const u8, now_ns: core.TimeNs) TurnPermissionChannelLifecycleError!TurnRelayedChannelData {
        try self.requireActive();
        const data = try self.channels.decode(input);
        const binding = self.channels.binding(data.number) orelse return error.UnknownChannel;
        if (!self.permissions.authorized(binding.peer, now_ns)) return error.UnauthorizedPeer;
        return .{ .peer = binding.peer, .payload = data.payload };
    }

    pub fn poll(self: *TurnPermissionChannelLifecycle, now_ns: core.TimeNs) TurnPermissionChannelLifecycleError!usize {
        try self.requireActive();
        self.permissions.expire(now_ns);
        var removed: usize = 0;
        var index: usize = 0;
        while (index < self.channels.bindings.items.len) {
            const peer = self.channels.bindings.items[index].peer;
            if (self.permissions.authorized(peer, now_ns)) {
                index += 1;
                continue;
            }
            _ = self.channels.bindings.orderedRemove(index);
            removed += 1;
        }
        return removed;
    }

    pub fn teardown(self: *TurnPermissionChannelLifecycle) void {
        if (self.closed) return;
        self.permissions.clear();
        self.channels.clear();
        self.closed = true;
    }

    fn nextAvailableChannel(self: *TurnPermissionChannelLifecycle) TurnPermissionChannelLifecycleError!u16 {
        var candidate = self.next_channel;
        var attempts: usize = 0;
        const range = @as(usize, channels.turn_channel_max - channels.turn_channel_min + 1);
        while (attempts < range) : (attempts += 1) {
            if (self.channels.binding(candidate) == null) return candidate;
            candidate = if (candidate == channels.turn_channel_max) channels.turn_channel_min else candidate + 1;
        }
        return error.ChannelUnavailable;
    }

    fn requireActive(self: TurnPermissionChannelLifecycle) TurnPermissionChannelLifecycleError!void {
        if (self.closed) return error.Closed;
    }
};

test "TURN permission channel lifecycles renew assign and reject unauthorized relay injection" {
    var lifecycle = try TurnPermissionChannelLifecycle.init(std.testing.allocator, .{ .maximum_permissions = 2, .permission_lifetime_ns = 10, .maximum_channels = 2 });
    defer lifecycle.deinit();
    const peer = protocol.StunAddress{ .ipv4 = .{ .octets = .{ 1, 2, 3, 4 }, .port = 9 } };
    const other = protocol.StunAddress{ .ipv4 = .{ .octets = .{ 5, 6, 7, 8 }, .port = 10 } };
    try std.testing.expectError(error.UnauthorizedPeer, lifecycle.assign_channel(peer, null, 0));
    _ = try lifecycle.authorize_peer(peer, 0);
    const binding = try lifecycle.assign_channel(peer, null, 0);
    try std.testing.expectEqual(channels.turn_channel_min, binding.number);
    _ = try lifecycle.authorize_peer(other, 0);
    try std.testing.expectError(error.ChannelCollision, lifecycle.assign_channel(other, binding.number, 0));
    var frame: [7]u8 = undefined;
    const encoded = try lifecycle.channels.encode(.{ .number = binding.number, .payload = "abc" }, frame[0..]);
    try std.testing.expectEqual(peer, (try lifecycle.receive_channel(encoded, 9)).peer);
    _ = try lifecycle.renew_permission(other, 9);
    try std.testing.expectError(error.UnauthorizedPeer, lifecycle.receive_channel(encoded, 10));
    try std.testing.expectEqual(@as(usize, 1), try lifecycle.poll(10));
    try std.testing.expectEqual(@as(usize, 0), lifecycle.channels.count());
    lifecycle.teardown();
    try std.testing.expectError(error.Closed, lifecycle.authorize_peer(peer, 11));
}
