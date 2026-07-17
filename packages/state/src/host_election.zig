const migration = @import("migration_coordinator.zig");

pub const HostElectionOrder = enum { lowest_healthy_peer_id };
pub const HostElectionMember = struct {
    id: migration.MigrationHostId,
    health: migration.MigrationHostHealth,
    eligible: bool = true,
};
pub const HostElection = struct {
    host: migration.MigrationHostId,
    membership_revision: u64,
    order: HostElectionOrder = .lowest_healthy_peer_id,
};
pub const HostElectionError = error{ InvalidConfiguration, MemberCapacityExceeded, InvalidMember, DuplicateMember, NoEligibleHost };
pub const HostElectionConfig = struct { maximum_members: usize };

pub const HostElector = struct {
    config: HostElectionConfig,

    pub fn init(config: HostElectionConfig) HostElectionError!HostElector {
        if (config.maximum_members == 0) return error.InvalidConfiguration;
        return .{ .config = config };
    }
    pub fn elect(self: HostElector, members: []const HostElectionMember, membership_revision: u64) HostElectionError!HostElection {
        if (members.len == 0) return error.NoEligibleHost;
        if (members.len > self.config.maximum_members) return error.MemberCapacityExceeded;
        var selected: ?migration.MigrationHostId = null;
        for (members, 0..) |member, index| {
            if (member.id == 0) return error.InvalidMember;
            for (members[0..index]) |previous| if (previous.id == member.id) return error.DuplicateMember;
            if (!member.eligible or member.health != .healthy) continue;
            if (selected == null or member.id < selected.?) selected = member.id;
        }
        return .{ .host = selected orelse return error.NoEligibleHost, .membership_revision = membership_revision };
    }
};

test "host election selects the lowest eligible healthy peer independent of member order" {
    const elector = try HostElector.init(.{ .maximum_members = 3 });
    const members = [_]HostElectionMember{
        .{ .id = 7, .health = .healthy },
        .{ .id = 2, .health = .degraded },
        .{ .id = 4, .health = .healthy },
    };
    try @import("std").testing.expectEqual(HostElection{ .host = 4, .membership_revision = 9 }, try elector.elect(members[0..], 9));
    const reordered = [_]HostElectionMember{ members[2], members[0], members[1] };
    try @import("std").testing.expectEqual(HostElection{ .host = 4, .membership_revision = 9 }, try elector.elect(reordered[0..], 9));
}

test "host election rejects unbounded malformed duplicate and ineligible memberships" {
    const elector = try HostElector.init(.{ .maximum_members = 1 });
    const unavailable = [_]HostElectionMember{.{ .id = 1, .health = .unavailable }};
    try @import("std").testing.expectError(error.NoEligibleHost, elector.elect(unavailable[0..], 1));
    const duplicate = [_]HostElectionMember{ .{ .id = 1, .health = .healthy }, .{ .id = 1, .health = .healthy } };
    const larger = try HostElector.init(.{ .maximum_members = 2 });
    try @import("std").testing.expectError(error.DuplicateMember, larger.elect(duplicate[0..], 1));
    try @import("std").testing.expectError(error.MemberCapacityExceeded, elector.elect(duplicate[0..], 1));
    try @import("std").testing.expectError(error.InvalidConfiguration, HostElector.init(.{ .maximum_members = 0 }));
}
