const std = @import("std");
const host = @import("authoritative_host.zig");

pub const max_dedicated_session_participants: usize = 1_000;
pub const DedicatedScheduledWork = struct { peer: host.HostPeerId, sequence: u64 };
pub const DedicatedSessionSchedulerError = std.mem.Allocator.Error || error{ InvalidConfiguration, ParticipantCapacityExceeded, DuplicateParticipant, UnknownParticipant, PendingWorkCapacityExceeded, WorkSequenceExhausted };
pub const DedicatedSessionSchedulerConfig = struct {
    maximum_participants: usize,
    maximum_work_per_pump: usize,
    maximum_fanout_per_tick: usize,
    maximum_pending_work_per_participant: u16,
};

const Participant = struct {
    peer: host.HostPeerId,
    interested: bool = false,
    pending_work: u16 = 0,
};

pub const DedicatedSessionScheduler = struct {
    allocator: std.mem.Allocator,
    config: DedicatedSessionSchedulerConfig,
    participants: std.ArrayListUnmanaged(Participant) = .empty,
    work_cursor: usize = 0,
    fanout_cursor: usize = 0,
    next_work_sequence: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, config: DedicatedSessionSchedulerConfig) DedicatedSessionSchedulerError!DedicatedSessionScheduler {
        if (config.maximum_participants == 0 or config.maximum_participants > max_dedicated_session_participants or config.maximum_work_per_pump == 0 or config.maximum_fanout_per_tick == 0 or config.maximum_pending_work_per_participant == 0) return error.InvalidConfiguration;
        return .{ .allocator = allocator, .config = config };
    }
    pub fn deinit(self: *DedicatedSessionScheduler) void {
        self.participants.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn register(self: *DedicatedSessionScheduler, peer: host.HostPeerId) DedicatedSessionSchedulerError!void {
        if (peer == 0) return error.InvalidConfiguration;
        const insertion = self.insertion_index(peer);
        if (insertion < self.participants.items.len and self.participants.items[insertion].peer == peer) return error.DuplicateParticipant;
        if (self.participants.items.len == self.config.maximum_participants) return error.ParticipantCapacityExceeded;
        try self.participants.ensureUnusedCapacity(self.allocator, 1);
        self.participants.appendAssumeCapacity(.{ .peer = peer });
        var index = self.participants.items.len - 1;
        while (index > insertion) : (index -= 1) self.participants.items[index] = self.participants.items[index - 1];
        self.participants.items[insertion] = .{ .peer = peer };
        self.normalize_cursors();
    }
    pub fn unregister(self: *DedicatedSessionScheduler, peer: host.HostPeerId) DedicatedSessionSchedulerError!void {
        const index = self.index_of(peer) orelse return error.UnknownParticipant;
        _ = self.participants.orderedRemove(index);
        self.normalize_cursors();
    }
    pub fn set_interest(self: *DedicatedSessionScheduler, peer: host.HostPeerId, interested: bool) DedicatedSessionSchedulerError!void {
        const participant = self.participant_ptr(peer) orelse return error.UnknownParticipant;
        participant.interested = interested;
    }
    pub fn enqueue_work(self: *DedicatedSessionScheduler, peer: host.HostPeerId) DedicatedSessionSchedulerError!void {
        const participant = self.participant_ptr(peer) orelse return error.UnknownParticipant;
        if (participant.pending_work == self.config.maximum_pending_work_per_participant) return error.PendingWorkCapacityExceeded;
        participant.pending_work += 1;
    }
    pub fn schedule(self: *DedicatedSessionScheduler, output: []DedicatedScheduledWork) DedicatedSessionSchedulerError!usize {
        const limit = @min(output.len, self.config.maximum_work_per_pump);
        if (limit == 0 or self.participants.items.len == 0) return 0;
        var count: usize = 0;
        var inspected: usize = 0;
        var index = self.work_cursor;
        while (count < limit and inspected < self.participants.items.len) : (inspected += 1) {
            const participant = &self.participants.items[index];
            if (participant.pending_work != 0) {
                if (self.next_work_sequence == std.math.maxInt(u64)) return error.WorkSequenceExhausted;
                output[count] = .{ .peer = participant.peer, .sequence = self.next_work_sequence };
                participant.pending_work -= 1;
                self.next_work_sequence += 1;
                count += 1;
            }
            index = (index + 1) % self.participants.items.len;
        }
        self.work_cursor = index;
        return count;
    }
    pub fn fanout(self: *DedicatedSessionScheduler, output: []host.HostPeerId) usize {
        const limit = @min(output.len, self.config.maximum_fanout_per_tick);
        if (limit == 0 or self.participants.items.len == 0) return 0;
        var count: usize = 0;
        var inspected: usize = 0;
        var index = self.fanout_cursor;
        while (count < limit and inspected < self.participants.items.len) : (inspected += 1) {
            if (self.participants.items[index].interested) {
                output[count] = self.participants.items[index].peer;
                count += 1;
            }
            index = (index + 1) % self.participants.items.len;
        }
        self.fanout_cursor = index;
        return count;
    }
    fn participant_ptr(self: *DedicatedSessionScheduler, peer: host.HostPeerId) ?*Participant {
        const index = self.index_of(peer) orelse return null;
        return &self.participants.items[index];
    }
    fn index_of(self: DedicatedSessionScheduler, peer: host.HostPeerId) ?usize {
        const index = self.insertion_index(peer);
        if (index == self.participants.items.len or self.participants.items[index].peer != peer) return null;
        return index;
    }
    fn insertion_index(self: DedicatedSessionScheduler, peer: host.HostPeerId) usize {
        for (self.participants.items, 0..) |participant, index| if (participant.peer >= peer) return index;
        return self.participants.items.len;
    }
    fn normalize_cursors(self: *DedicatedSessionScheduler) void {
        if (self.participants.items.len == 0) {
            self.work_cursor = 0;
            self.fanout_cursor = 0;
            return;
        }
        self.work_cursor %= self.participants.items.len;
        self.fanout_cursor %= self.participants.items.len;
    }
};

test "dedicated session scheduler fairly bounds work and interest-aware fanout" {
    var scheduler = try DedicatedSessionScheduler.init(std.testing.allocator, .{ .maximum_participants = 3, .maximum_work_per_pump = 2, .maximum_fanout_per_tick = 2, .maximum_pending_work_per_participant = 2 });
    defer scheduler.deinit();
    try scheduler.register(3);
    try scheduler.register(1);
    try scheduler.register(2);
    try scheduler.set_interest(1, true);
    try scheduler.set_interest(3, true);
    try scheduler.enqueue_work(1);
    try scheduler.enqueue_work(2);
    try scheduler.enqueue_work(3);
    var work: [2]DedicatedScheduledWork = undefined;
    try std.testing.expectEqual(@as(usize, 2), try scheduler.schedule(work[0..]));
    try std.testing.expectEqual(DedicatedScheduledWork{ .peer = 1, .sequence = 0 }, work[0]);
    try std.testing.expectEqual(DedicatedScheduledWork{ .peer = 2, .sequence = 1 }, work[1]);
    try std.testing.expectEqual(@as(usize, 1), try scheduler.schedule(work[0..]));
    try std.testing.expectEqual(DedicatedScheduledWork{ .peer = 3, .sequence = 2 }, work[0]);
    var peers: [2]host.HostPeerId = undefined;
    try std.testing.expectEqual(@as(usize, 2), scheduler.fanout(peers[0..]));
    try std.testing.expectEqualSlices(host.HostPeerId, &.{ 1, 3 }, peers[0..]);
}

test "dedicated session scheduler rejects over-capacity duplicate and queued work" {
    var scheduler = try DedicatedSessionScheduler.init(std.testing.allocator, .{ .maximum_participants = 1, .maximum_work_per_pump = 1, .maximum_fanout_per_tick = 1, .maximum_pending_work_per_participant = 1 });
    defer scheduler.deinit();
    try scheduler.register(1);
    try std.testing.expectError(error.DuplicateParticipant, scheduler.register(1));
    try std.testing.expectError(error.ParticipantCapacityExceeded, scheduler.register(2));
    try scheduler.enqueue_work(1);
    try std.testing.expectError(error.PendingWorkCapacityExceeded, scheduler.enqueue_work(1));
    try std.testing.expectError(error.UnknownParticipant, scheduler.set_interest(2, true));
    try std.testing.expectError(error.InvalidConfiguration, DedicatedSessionScheduler.init(std.testing.allocator, .{ .maximum_participants = max_dedicated_session_participants + 1, .maximum_work_per_pump = 1, .maximum_fanout_per_tick = 1, .maximum_pending_work_per_participant = 1 }));
}
