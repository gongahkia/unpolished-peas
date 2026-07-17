const std = @import("std");
const core = @import("minna-san-core");
const protocol = @import("minna-san-protocol");

pub const TurnPermissionError = std.mem.Allocator.Error || error{ InvalidConfiguration, InvalidPeer, PermissionCapacityExceeded, PermissionExpired, UnauthorizedPeer };
pub const TurnPermissionConfig = struct { maximum_permissions: usize, lifetime_ns: core.TimeNs };
pub const TurnPermission = struct { peer: protocol.StunAddress, expires_at_ns: core.TimeNs };

pub const TurnPermissions = struct {
    allocator: std.mem.Allocator,
    config: TurnPermissionConfig,
    permissions: std.ArrayListUnmanaged(TurnPermission) = .empty,

    pub fn init(allocator: std.mem.Allocator, config: TurnPermissionConfig) TurnPermissionError!TurnPermissions {
        if (config.maximum_permissions == 0 or config.lifetime_ns == 0) return error.InvalidConfiguration;
        return .{ .allocator = allocator, .config = config };
    }
    pub fn deinit(self: *TurnPermissions) void {
        self.permissions.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn count(self: TurnPermissions) usize {
        return self.permissions.items.len;
    }
    pub fn authorize(self: *TurnPermissions, peer: protocol.StunAddress, now_ns: core.TimeNs) TurnPermissionError!TurnPermission {
        try validate_peer(peer);
        self.expire(now_ns);
        const expires_at_ns = now_ns +| self.config.lifetime_ns;
        if (self.index_of(peer)) |index| {
            self.permissions.items[index].expires_at_ns = expires_at_ns;
            return self.permissions.items[index];
        }
        if (self.permissions.items.len == self.config.maximum_permissions) return error.PermissionCapacityExceeded;
        try self.permissions.append(self.allocator, .{ .peer = peer, .expires_at_ns = expires_at_ns });
        return self.permissions.items[self.permissions.items.len - 1];
    }
    pub fn refresh(self: *TurnPermissions, peer: protocol.StunAddress, now_ns: core.TimeNs) TurnPermissionError!TurnPermission {
        const index = self.index_of(peer) orelse return error.UnauthorizedPeer;
        if (self.permissions.items[index].expires_at_ns <= now_ns) {
            _ = self.permissions.orderedRemove(index);
            return error.PermissionExpired;
        }
        self.permissions.items[index].expires_at_ns = now_ns +| self.config.lifetime_ns;
        return self.permissions.items[index];
    }
    pub fn authorized(self: *TurnPermissions, peer: protocol.StunAddress, now_ns: core.TimeNs) bool {
        self.expire(now_ns);
        return self.index_of(peer) != null;
    }
    pub fn expire(self: *TurnPermissions, now_ns: core.TimeNs) void {
        var index: usize = 0;
        while (index < self.permissions.items.len) {
            if (self.permissions.items[index].expires_at_ns <= now_ns) {
                _ = self.permissions.orderedRemove(index);
                continue;
            }
            index += 1;
        }
    }
    fn index_of(self: TurnPermissions, peer: protocol.StunAddress) ?usize {
        for (self.permissions.items, 0..) |permission, index| if (std.meta.eql(permission.peer, peer)) return index;
        return null;
    }
};

fn validate_peer(peer: protocol.StunAddress) TurnPermissionError!void {
    switch (peer) {
        .ipv4 => |address| if (address.port == 0) return error.InvalidPeer,
        .ipv6 => |address| if (address.port == 0) return error.InvalidPeer,
    }
}

test "TURN permissions authorize refresh expire and bound peer access" {
    var permissions = try TurnPermissions.init(std.testing.allocator, .{ .maximum_permissions = 1, .lifetime_ns = 10 });
    defer permissions.deinit();
    const peer = protocol.StunAddress{ .ipv4 = .{ .octets = .{ 1, 2, 3, 4 }, .port = 9 } };
    try std.testing.expectEqual(@as(core.TimeNs, 10), (try permissions.authorize(peer, 0)).expires_at_ns);
    try std.testing.expect(permissions.authorized(peer, 9));
    try std.testing.expectEqual(@as(core.TimeNs, 19), (try permissions.refresh(peer, 9)).expires_at_ns);
    try std.testing.expect(!permissions.authorized(peer, 19));
    try std.testing.expectEqual(@as(usize, 0), permissions.count());
    try std.testing.expectError(error.UnauthorizedPeer, permissions.refresh(peer, 19));
}

test "TURN permissions reject invalid and over-capacity peers" {
    var permissions = try TurnPermissions.init(std.testing.allocator, .{ .maximum_permissions = 1, .lifetime_ns = 1 });
    defer permissions.deinit();
    const first = protocol.StunAddress{ .ipv4 = .{ .octets = .{ 1, 1, 1, 1 }, .port = 1 } };
    const second = protocol.StunAddress{ .ipv6 = .{ .octets = .{0} ** 15 ++ .{1}, .port = 2 } };
    _ = try permissions.authorize(first, 0);
    try std.testing.expectError(error.PermissionCapacityExceeded, permissions.authorize(second, 0));
    try std.testing.expectError(error.InvalidPeer, permissions.authorize(.{ .ipv4 = .{ .octets = .{ 0, 0, 0, 0 }, .port = 0 } }, 0));
    try std.testing.expectError(error.InvalidConfiguration, TurnPermissions.init(std.testing.allocator, .{ .maximum_permissions = 0, .lifetime_ns = 1 }));
}
