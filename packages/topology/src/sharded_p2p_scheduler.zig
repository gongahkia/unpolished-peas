const std = @import("std");
const groups = @import("routed_peer_group.zig");
const discovery = @import("peer_discovery.zig");

pub const max_sharded_p2p_participants: usize = 1_000;
pub const ShardedP2PDispatch = struct {
    group: groups.PeerGroupId,
    recipient: groups.PeerGroupPeerId,
    path: groups.PeerGroupPath,
};
pub const ShardedP2PSchedulerError = std.mem.Allocator.Error || discovery.PeerDiscoveryError || error{ InvalidConfiguration, ParticipantCapacityExceeded, GroupCapacityExceeded, DuplicateParticipant, UnknownParticipant, SignalTooLarge };
pub const ShardedP2PSchedulerConfig = struct {
    maximum_groups: usize,
    maximum_participants: usize,
    maximum_dispatches_per_pump: usize,
    maximum_signal_bytes: usize,
    hooks: discovery.PeerDiscoveryHooks,
};

const Participant = struct {
    group: groups.PeerGroupId,
    peer: groups.PeerGroupPeerId,
    path: groups.PeerGroupPath,
    interested: bool = false,
};

pub const ShardedP2PScheduler = struct {
    allocator: std.mem.Allocator,
    config: ShardedP2PSchedulerConfig,
    participants: std.ArrayListUnmanaged(Participant) = .empty,
    group_count: usize = 0,
    cursor: usize = 0,

    pub fn init(allocator: std.mem.Allocator, config: ShardedP2PSchedulerConfig) ShardedP2PSchedulerError!ShardedP2PScheduler {
        if (config.maximum_groups == 0 or config.maximum_participants == 0 or config.maximum_participants > max_sharded_p2p_participants or config.maximum_dispatches_per_pump == 0 or config.maximum_signal_bytes == 0) return error.InvalidConfiguration;
        return .{ .allocator = allocator, .config = config };
    }
    pub fn deinit(self: *ShardedP2PScheduler) void {
        self.participants.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn register(self: *ShardedP2PScheduler, group: groups.PeerGroupId, route: groups.PeerGroupRoute) ShardedP2PSchedulerError!void {
        if (group == 0 or route.peer == 0 or !valid_path(route.path)) return error.InvalidConfiguration;
        const insertion = self.insertion_index(group, route.peer);
        if (insertion < self.participants.items.len and same_participant(self.participants.items[insertion], group, route.peer)) return error.DuplicateParticipant;
        if (self.participants.items.len == self.config.maximum_participants) return error.ParticipantCapacityExceeded;
        const new_group = !self.has_group(group);
        if (new_group and self.group_count == self.config.maximum_groups) return error.GroupCapacityExceeded;
        try self.participants.ensureUnusedCapacity(self.allocator, 1);
        self.participants.appendAssumeCapacity(.{ .group = group, .peer = route.peer, .path = route.path });
        var index = self.participants.items.len - 1;
        while (index > insertion) : (index -= 1) self.participants.items[index] = self.participants.items[index - 1];
        self.participants.items[insertion] = .{ .group = group, .peer = route.peer, .path = route.path };
        if (new_group) self.group_count += 1;
        self.normalize_cursor();
    }
    pub fn unregister(self: *ShardedP2PScheduler, group: groups.PeerGroupId, peer: groups.PeerGroupPeerId) ShardedP2PSchedulerError!void {
        const index = self.index_of(group, peer) orelse return error.UnknownParticipant;
        _ = self.participants.orderedRemove(index);
        if (!self.has_group(group)) self.group_count -= 1;
        self.normalize_cursor();
    }
    pub fn set_interest(self: *ShardedP2PScheduler, group: groups.PeerGroupId, peer: groups.PeerGroupPeerId, interested: bool) ShardedP2PSchedulerError!void {
        const participant = self.participant_ptr(group, peer) orelse return error.UnknownParticipant;
        participant.interested = interested;
    }
    pub fn schedule(self: *ShardedP2PScheduler, output: []ShardedP2PDispatch) usize {
        const limit = @min(output.len, self.config.maximum_dispatches_per_pump);
        if (limit == 0 or self.participants.items.len == 0) return 0;
        var count: usize = 0;
        var inspected: usize = 0;
        var index = self.cursor;
        while (count < limit and inspected < self.participants.items.len) : (inspected += 1) {
            const participant = self.participants.items[index];
            if (participant.interested) {
                output[count] = .{ .group = participant.group, .recipient = participant.peer, .path = participant.path };
                count += 1;
            }
            index = (index + 1) % self.participants.items.len;
        }
        self.cursor = index;
        return count;
    }
    pub fn signal(self: ShardedP2PScheduler, group: groups.PeerGroupId, sender: groups.PeerGroupPeerId, recipient: groups.PeerGroupPeerId, payload: []const u8) ShardedP2PSchedulerError!void {
        if (payload.len > self.config.maximum_signal_bytes) return error.SignalTooLarge;
        _ = self.index_of(group, sender) orelse return error.UnknownParticipant;
        _ = self.index_of(group, recipient) orelse return error.UnknownParticipant;
        return self.config.hooks.signal(.{ .group = group, .sender = sender, .recipient = recipient, .payload = payload });
    }
    fn participant_ptr(self: *ShardedP2PScheduler, group: groups.PeerGroupId, peer: groups.PeerGroupPeerId) ?*Participant {
        const index = self.index_of(group, peer) orelse return null;
        return &self.participants.items[index];
    }
    fn index_of(self: ShardedP2PScheduler, group: groups.PeerGroupId, peer: groups.PeerGroupPeerId) ?usize {
        const index = self.insertion_index(group, peer);
        if (index == self.participants.items.len or !same_participant(self.participants.items[index], group, peer)) return null;
        return index;
    }
    fn insertion_index(self: ShardedP2PScheduler, group: groups.PeerGroupId, peer: groups.PeerGroupPeerId) usize {
        for (self.participants.items, 0..) |participant, index| {
            if (participant.group > group or (participant.group == group and participant.peer >= peer)) return index;
        }
        return self.participants.items.len;
    }
    fn has_group(self: ShardedP2PScheduler, group: groups.PeerGroupId) bool {
        for (self.participants.items) |participant| if (participant.group == group) return true;
        return false;
    }
    fn normalize_cursor(self: *ShardedP2PScheduler) void {
        if (self.participants.items.len == 0) {
            self.cursor = 0;
            return;
        }
        self.cursor %= self.participants.items.len;
    }
};

fn valid_path(path: groups.PeerGroupPath) bool {
    return switch (path) {
        .direct => |route| route != 0,
        .relay => |relay| relay.ingress != 0 and relay.egress != 0,
    };
}

fn same_participant(participant: Participant, group: groups.PeerGroupId, peer: groups.PeerGroupPeerId) bool {
    return participant.group == group and participant.peer == peer;
}

test "sharded P2P scheduler bounds group dispatches and signals direct relay routes" {
    const Fixture = struct {
        signals: usize = 0,
        fn discover(_: *anyopaque, _: discovery.DiscoveryRequest, _: []discovery.DiscoveryCandidate) discovery.PeerDiscoveryError!usize {
            return 0;
        }
        fn rendezvous(_: *anyopaque, _: discovery.RendezvousRequest) discovery.PeerDiscoveryError!void {}
        fn signal(context: *anyopaque, _: discovery.SignalingMessage) discovery.PeerDiscoveryError!void {
            @as(*@This(), @ptrCast(@alignCast(context))).signals += 1;
        }
    };
    var fixture = Fixture{};
    const hooks = discovery.PeerDiscoveryHooks{ .context = &fixture, .discover_fn = Fixture.discover, .rendezvous_fn = Fixture.rendezvous, .signal_fn = Fixture.signal };
    var scheduler = try ShardedP2PScheduler.init(std.testing.allocator, .{ .maximum_groups = 1, .maximum_participants = 2, .maximum_dispatches_per_pump = 2, .maximum_signal_bytes = 4, .hooks = hooks });
    defer scheduler.deinit();
    try scheduler.register(1, .{ .peer = 1, .path = .{ .direct = 1 } });
    try scheduler.register(1, .{ .peer = 2, .path = .{ .relay = .{ .ingress = 2, .egress = 3 } } });
    try scheduler.set_interest(1, 1, true);
    try scheduler.set_interest(1, 2, true);
    var dispatches: [2]ShardedP2PDispatch = undefined;
    try std.testing.expectEqual(@as(usize, 2), scheduler.schedule(dispatches[0..]));
    try std.testing.expectEqual(groups.PeerGroupPath{ .direct = 1 }, dispatches[0].path);
    try std.testing.expectEqual(groups.PeerGroupPath{ .relay = .{ .ingress = 2, .egress = 3 } }, dispatches[1].path);
    try scheduler.signal(1, 1, 2, "ok");
    try std.testing.expectEqual(@as(usize, 1), fixture.signals);
}

test "sharded P2P scheduler rejects invalid group participant and signal bounds" {
    const Fixture = struct {
        fn discover(_: *anyopaque, _: discovery.DiscoveryRequest, _: []discovery.DiscoveryCandidate) discovery.PeerDiscoveryError!usize {
            return 0;
        }
        fn rendezvous(_: *anyopaque, _: discovery.RendezvousRequest) discovery.PeerDiscoveryError!void {}
        fn signal(_: *anyopaque, _: discovery.SignalingMessage) discovery.PeerDiscoveryError!void {}
    };
    var fixture = Fixture{};
    const hooks = discovery.PeerDiscoveryHooks{ .context = &fixture, .discover_fn = Fixture.discover, .rendezvous_fn = Fixture.rendezvous, .signal_fn = Fixture.signal };
    var scheduler = try ShardedP2PScheduler.init(std.testing.allocator, .{ .maximum_groups = 1, .maximum_participants = 1, .maximum_dispatches_per_pump = 1, .maximum_signal_bytes = 1, .hooks = hooks });
    defer scheduler.deinit();
    try scheduler.register(1, .{ .peer = 1, .path = .{ .direct = 1 } });
    try std.testing.expectError(error.DuplicateParticipant, scheduler.register(1, .{ .peer = 1, .path = .{ .direct = 1 } }));
    try std.testing.expectError(error.ParticipantCapacityExceeded, scheduler.register(1, .{ .peer = 2, .path = .{ .direct = 2 } }));
    try std.testing.expectError(error.UnknownParticipant, scheduler.signal(1, 1, 2, "x"));
    try std.testing.expectError(error.SignalTooLarge, scheduler.signal(1, 1, 1, "xx"));
    try std.testing.expectError(error.InvalidConfiguration, ShardedP2PScheduler.init(std.testing.allocator, .{ .maximum_groups = 1, .maximum_participants = max_sharded_p2p_participants + 1, .maximum_dispatches_per_pump = 1, .maximum_signal_bytes = 1, .hooks = hooks }));
}
