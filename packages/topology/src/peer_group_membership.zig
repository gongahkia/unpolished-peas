const std = @import("std");
const groups = @import("routed_peer_group.zig");

pub const MembershipEventKind = enum { joined, left };

pub const MembershipAuthorization = struct {
    context: *anyopaque,
    authorize_fn: *const fn (*anyopaque, groups.PeerGroupId, groups.PeerGroupPeerId) bool,

    pub fn authorize(self: MembershipAuthorization, group: groups.PeerGroupId, peer: groups.PeerGroupPeerId) bool {
        return self.authorize_fn(self.context, group, peer);
    }
};

pub const MembershipEvent = struct {
    kind: MembershipEventKind,
    group: groups.PeerGroupId,
    peer: groups.PeerGroupPeerId,
    leader: ?groups.PeerGroupPeerId,
};

pub const PeerGroupMembershipError = std.mem.Allocator.Error || error{ InvalidConfiguration, UnknownGroup, GroupClosed, AuthorizationRejected, MemberCapacityExceeded, AlreadyMember, UnknownMember };

pub const PeerGroupMembershipConfig = struct {
    maximum_members_per_group: usize,
    authorization: ?MembershipAuthorization = null,
};

const Membership = struct {
    group: groups.PeerGroupId,
    members: std.ArrayListUnmanaged(groups.PeerGroupPeerId) = .empty,

    fn deinit(self: *Membership, allocator: std.mem.Allocator) void {
        self.members.deinit(allocator);
        self.* = undefined;
    }
};

pub const PeerGroupMembership = struct {
    allocator: std.mem.Allocator,
    routed_groups: *const groups.RoutedPeerGroups,
    config: PeerGroupMembershipConfig,
    memberships: std.ArrayListUnmanaged(Membership) = .empty,

    pub fn init(allocator: std.mem.Allocator, routed_groups: *const groups.RoutedPeerGroups, config: PeerGroupMembershipConfig) PeerGroupMembershipError!PeerGroupMembership {
        if (config.maximum_members_per_group == 0) return error.InvalidConfiguration;
        return .{ .allocator = allocator, .routed_groups = routed_groups, .config = config };
    }

    pub fn deinit(self: *PeerGroupMembership) void {
        for (self.memberships.items) |*membership| membership.deinit(self.allocator);
        self.memberships.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn join(self: *PeerGroupMembership, group: groups.PeerGroupId, peer: groups.PeerGroupPeerId) PeerGroupMembershipError!MembershipEvent {
        try self.require_active_group(group);
        if (peer == 0) return error.InvalidConfiguration;
        if (self.config.authorization) |authorization| if (!authorization.authorize(group, peer)) return error.AuthorizationRejected;
        const membership = try self.membership_for(group);
        if (member_index(membership.*, peer) != null) return error.AlreadyMember;
        if (membership.members.items.len == self.config.maximum_members_per_group) return error.MemberCapacityExceeded;
        try membership.members.ensureUnusedCapacity(self.allocator, 1);
        const insertion = member_insertion_index(membership.*, peer);
        membership.members.appendAssumeCapacity(peer);
        var index = membership.members.items.len - 1;
        while (index > insertion) : (index -= 1) membership.members.items[index] = membership.members.items[index - 1];
        membership.members.items[insertion] = peer;
        return .{ .kind = .joined, .group = group, .peer = peer, .leader = membership.members.items[0] };
    }

    pub fn leave(self: *PeerGroupMembership, group: groups.PeerGroupId, peer: groups.PeerGroupPeerId) PeerGroupMembershipError!MembershipEvent {
        const membership = self.membership_ptr(group) orelse return error.UnknownMember;
        const index = member_index(membership.*, peer) orelse return error.UnknownMember;
        _ = membership.members.orderedRemove(index);
        return .{ .kind = .left, .group = group, .peer = peer, .leader = if (membership.members.items.len == 0) null else membership.members.items[0] };
    }

    pub fn leader(self: PeerGroupMembership, group: groups.PeerGroupId) ?groups.PeerGroupPeerId {
        const membership = self.membership_ptr_const(group) orelse return null;
        if (membership.members.items.len == 0) return null;
        return membership.members.items[0];
    }

    pub fn list(self: PeerGroupMembership, group: groups.PeerGroupId, output: []groups.PeerGroupPeerId) PeerGroupMembershipError!usize {
        const membership = self.membership_ptr_const(group) orelse return error.UnknownGroup;
        if (membership.members.items.len > output.len) return error.MemberCapacityExceeded;
        @memcpy(output[0..membership.members.items.len], membership.members.items);
        return membership.members.items.len;
    }

    fn require_active_group(self: PeerGroupMembership, group: groups.PeerGroupId) PeerGroupMembershipError!void {
        const info = self.routed_groups.info(group) orelse return error.UnknownGroup;
        if (info.state != .active) return error.GroupClosed;
    }

    fn membership_for(self: *PeerGroupMembership, group: groups.PeerGroupId) PeerGroupMembershipError!*Membership {
        if (self.membership_ptr(group)) |membership| return membership;
        try self.memberships.append(self.allocator, .{ .group = group });
        return &self.memberships.items[self.memberships.items.len - 1];
    }

    fn membership_ptr(self: *PeerGroupMembership, group: groups.PeerGroupId) ?*Membership {
        for (self.memberships.items) |*membership| if (membership.group == group) return membership;
        return null;
    }

    fn membership_ptr_const(self: PeerGroupMembership, group: groups.PeerGroupId) ?*const Membership {
        for (self.memberships.items) |*membership| if (membership.group == group) return membership;
        return null;
    }
};

fn member_index(membership: Membership, peer: groups.PeerGroupPeerId) ?usize {
    for (membership.members.items, 0..) |member, index| {
        if (member == peer) return index;
        if (member > peer) return null;
    }
    return null;
}

fn member_insertion_index(membership: Membership, peer: groups.PeerGroupPeerId) usize {
    for (membership.members.items, 0..) |member, index| if (member > peer) return index;
    return membership.members.items.len;
}

test "peer group membership authorizes capacity and deterministic leaders" {
    const Authorizer = struct {
        fn authorize(_: *anyopaque, _: groups.PeerGroupId, peer: groups.PeerGroupPeerId) bool {
            return peer != 4;
        }
    };
    var routed = try groups.RoutedPeerGroups.init(std.testing.allocator, .{ .maximum_groups = 1, .maximum_routes_per_group = 1 });
    defer routed.deinit();
    try routed.create(1);
    var context = Authorizer{};
    var membership = try PeerGroupMembership.init(std.testing.allocator, &routed, .{ .maximum_members_per_group = 2, .authorization = .{ .context = &context, .authorize_fn = Authorizer.authorize } });
    defer membership.deinit();
    try std.testing.expectEqual(@as(?groups.PeerGroupPeerId, 3), (try membership.join(1, 3)).leader);
    try std.testing.expectEqual(@as(?groups.PeerGroupPeerId, 2), (try membership.join(1, 2)).leader);
    var peers: [2]groups.PeerGroupPeerId = undefined;
    try std.testing.expectEqual(@as(usize, 2), try membership.list(1, peers[0..]));
    try std.testing.expectEqualSlices(groups.PeerGroupPeerId, &.{ 2, 3 }, peers[0..]);
    try std.testing.expectError(error.MemberCapacityExceeded, membership.join(1, 1));
    try std.testing.expectEqual(@as(?groups.PeerGroupPeerId, 3), (try membership.leave(1, 2)).leader);
    try std.testing.expectError(error.AuthorizationRejected, membership.join(1, 4));
    try std.testing.expectError(error.AlreadyMember, membership.join(1, 3));
    try routed.close(1);
    try std.testing.expectError(error.GroupClosed, membership.join(1, 5));
}
