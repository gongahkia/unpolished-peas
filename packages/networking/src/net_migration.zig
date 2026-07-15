const std = @import("std");
const contract = @import("net_contract.zig");
const p2p = @import("net_p2p.zig");

pub const Config = struct {
    max_members: u16 = 16,
    max_state_bytes: usize = 16 * 1024,
};
pub const GameState = struct { version: u16, tick: u64, bytes: []const u8 };
pub const Snapshot = struct { term: u32, host: contract.Identity, state: GameState };
pub const Decision = struct { route: p2p.Route, snapshot: Snapshot };
const Member = struct { identity: contract.Identity, active: bool = true };

pub const Coordinator = struct { // owns bounded member and state records; snapshots borrow it until the next publish/deinit.
    allocator: std.mem.Allocator,
    config: Config,
    members: std.ArrayListUnmanaged(Member) = .{},
    state: std.ArrayListUnmanaged(u8) = .{},
    host: ?contract.Identity = null,
    state_version: u16 = 0,
    tick: u64 = 0,
    term: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Coordinator {
        if (config.max_members < 2 or config.max_members > 64 or config.max_state_bytes == 0 or config.max_state_bytes > 64 * 1024) return error.InvalidMigrationConfig;
        return .{ .allocator = allocator, .config = config };
    }

    pub fn deinit(self: *Coordinator) void {
        self.members.deinit(self.allocator);
        self.state.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn join(self: *Coordinator, identity: contract.Identity) !void {
        if (self.findMember(identity)) |participant| {
            participant.active = true;
            return;
        }
        if (self.members.items.len >= self.config.max_members) return error.MigrationMemberLimit;
        try self.members.append(self.allocator, .{ .identity = identity });
    }

    pub fn appoint(self: *Coordinator, identity: contract.Identity) !void {
        const participant = self.findMember(identity) orelse return error.UnknownMigrationMember;
        if (!participant.active) return error.InactiveMigrationMember;
        self.host = identity;
        if (self.term == 0) self.term = 1;
    }

    pub fn publish(self: *Coordinator, identity: contract.Identity, state: GameState) !void {
        const host = self.host orelse return error.MigrationHostUnavailable;
        if (host.value != identity.value) return error.MigrationHostForbidden;
        if (!(self.findMember(identity) orelse return error.UnknownMigrationMember).active) return error.InactiveMigrationMember;
        if (state.version == 0 or state.bytes.len == 0) return error.InvalidMigrationState;
        if (state.bytes.len > self.config.max_state_bytes) return error.MigrationStateTooLarge;
        self.state.clearRetainingCapacity();
        try self.state.appendSlice(self.allocator, state.bytes);
        self.state_version = state.version;
        self.tick = state.tick;
    }

    pub fn failHost(self: *Coordinator, identity: contract.Identity, route: p2p.Route) !Decision {
        const host = self.host orelse return error.MigrationHostUnavailable;
        if (host.value != identity.value) return error.NotCurrentMigrationHost;
        if (self.state.items.len == 0) return error.MigrationStateUnavailable;
        const participant = self.findMember(identity) orelse return error.UnknownMigrationMember;
        const successor = self.electExcluding(identity) orelse return error.MigrationHostUnavailable;
        participant.active = false;
        self.host = successor;
        self.term +%= 1;
        if (self.term == 0) self.term = 1;
        return .{ .route = route, .snapshot = try self.snapshot() };
    }

    pub fn fallbackAfterPeerFailure(self: *Coordinator, identity: contract.Identity) !Decision {
        return self.failHost(identity, .relay);
    }

    pub fn reconnect(self: *Coordinator, identity: contract.Identity) !Snapshot {
        const participant = self.findMember(identity) orelse return error.UnknownMigrationMember;
        participant.active = true;
        return self.snapshot();
    }

    pub fn snapshot(self: *const Coordinator) !Snapshot {
        return .{ .term = self.term, .host = self.host orelse return error.MigrationHostUnavailable, .state = .{ .version = self.state_version, .tick = self.tick, .bytes = self.state.items } };
    }

    fn findMember(self: *Coordinator, identity: contract.Identity) ?*Member {
        for (self.members.items) |*participant| if (participant.identity.value == identity.value) return participant;
        return null;
    }

    fn electExcluding(self: *const Coordinator, excluded: contract.Identity) ?contract.Identity {
        var selected: ?contract.Identity = null;
        for (self.members.items) |participant| {
            if (!participant.active or participant.identity.value == excluded.value) continue;
            if (selected == null or participant.identity.value < selected.?.value) selected = participant.identity;
        }
        return selected;
    }
};

test "relay host migration preserves documented game state" {
    var coordinator = try Coordinator.init(std.testing.allocator, .{});
    defer coordinator.deinit();
    const host = try contract.Identity.init(30);
    const first_client = try contract.Identity.init(10);
    const second_client = try contract.Identity.init(20);
    try coordinator.join(host);
    try coordinator.join(first_client);
    try coordinator.join(second_client);
    try coordinator.appoint(host);
    try coordinator.publish(host, .{ .version = 1, .tick = 42, .bytes = "topdown-state/v1;players=2;position=80,48" });
    const decision = try coordinator.fallbackAfterPeerFailure(host);
    try std.testing.expectEqual(p2p.Route.relay, decision.route);
    try std.testing.expectEqual(@as(u32, 2), decision.snapshot.term);
    try std.testing.expectEqual(first_client.value, decision.snapshot.host.value);
    try std.testing.expectEqual(@as(u16, 1), decision.snapshot.state.version);
    try std.testing.expectEqual(@as(u64, 42), decision.snapshot.state.tick);
    try std.testing.expectEqualStrings("topdown-state/v1;players=2;position=80,48", decision.snapshot.state.bytes);
    const reconnected = try coordinator.reconnect(host);
    try std.testing.expectEqual(decision.snapshot.host.value, reconnected.host.value);
    try std.testing.expectEqualStrings(decision.snapshot.state.bytes, reconnected.state.bytes);
}

test "failure and reconnect matrix elects deterministic relay successors" {
    for ([_]p2p.Route{ .direct, .relay }) |route| {
        var coordinator = try Coordinator.init(std.testing.allocator, .{ .max_members = 3, .max_state_bytes = 64 });
        defer coordinator.deinit();
        const first = try contract.Identity.init(3);
        const second = try contract.Identity.init(1);
        const third = try contract.Identity.init(2);
        try coordinator.join(first);
        try coordinator.join(second);
        try coordinator.join(third);
        try coordinator.appoint(first);
        try coordinator.publish(first, .{ .version = 1, .tick = 7, .bytes = "state/v1" });
        const first_migration = try coordinator.failHost(first, route);
        try std.testing.expectEqual(route, first_migration.route);
        try std.testing.expectEqual(second.value, first_migration.snapshot.host.value);
        try std.testing.expectEqualStrings("state/v1", first_migration.snapshot.state.bytes);
        try coordinator.publish(second, .{ .version = 1, .tick = 8, .bytes = "state/v1;continued" });
        const second_migration = try coordinator.failHost(second, .relay);
        try std.testing.expectEqual(third.value, second_migration.snapshot.host.value);
        try std.testing.expectEqual(@as(u64, 8), second_migration.snapshot.state.tick);
        try std.testing.expectEqualStrings("state/v1;continued", second_migration.snapshot.state.bytes);
        const reconnect = try coordinator.reconnect(first);
        try std.testing.expectEqual(third.value, reconnect.host.value);
        try std.testing.expectEqualStrings(second_migration.snapshot.state.bytes, reconnect.state.bytes);
    }
}
