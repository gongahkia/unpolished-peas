const std = @import("std");
const core = @import("minna-san-core");

pub const max_liveness_peers: usize = 1_000;
pub const PeerLivenessState = enum { active, suspect, removed };
pub const PeerLivenessEvent = union(enum) {
    heartbeat: u64,
    suspect: u64,
    removed: u64,
    reconnected: u64,
};
pub const PeerLivenessError = std.mem.Allocator.Error || error{ InvalidConfiguration, PeerCapacityExceeded, DuplicatePeer, UnknownPeer, PeerRemoved };
pub const PeerLivenessConfig = struct {
    maximum_peers: usize,
    heartbeat_interval_ns: core.TimeNs,
    idle_timeout_ns: core.TimeNs,
    reconnect_window_ns: core.TimeNs,
    maximum_events_per_poll: usize,
};

const Peer = struct {
    id: u64,
    state: PeerLivenessState = .active,
    last_seen_ns: core.TimeNs,
    next_heartbeat_ns: core.TimeNs,
    suspect_since_ns: ?core.TimeNs = null,
};

pub const PeerLiveness = struct {
    allocator: std.mem.Allocator,
    config: PeerLivenessConfig,
    peers: std.ArrayListUnmanaged(Peer) = .empty,
    cursor: usize = 0,

    pub fn init(allocator: std.mem.Allocator, config: PeerLivenessConfig) PeerLivenessError!PeerLiveness {
        if (config.maximum_peers == 0 or config.maximum_peers > max_liveness_peers or config.heartbeat_interval_ns == 0 or config.idle_timeout_ns == 0 or config.heartbeat_interval_ns > config.idle_timeout_ns or config.reconnect_window_ns == 0 or config.maximum_events_per_poll == 0) return error.InvalidConfiguration;
        return .{ .allocator = allocator, .config = config };
    }
    pub fn deinit(self: *PeerLiveness) void {
        self.peers.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn register(self: *PeerLiveness, id: u64, now_ns: core.TimeNs) PeerLivenessError!void {
        if (id == 0) return error.InvalidConfiguration;
        const insertion = self.insertion_index(id);
        if (insertion < self.peers.items.len and self.peers.items[insertion].id == id) return error.DuplicatePeer;
        if (self.peers.items.len == self.config.maximum_peers) return error.PeerCapacityExceeded;
        try self.peers.ensureUnusedCapacity(self.allocator, 1);
        self.peers.appendAssumeCapacity(.{ .id = id, .last_seen_ns = now_ns, .next_heartbeat_ns = now_ns +| self.config.heartbeat_interval_ns });
        var index = self.peers.items.len - 1;
        while (index > insertion) : (index -= 1) self.peers.items[index] = self.peers.items[index - 1];
        self.peers.items[insertion] = .{ .id = id, .last_seen_ns = now_ns, .next_heartbeat_ns = now_ns +| self.config.heartbeat_interval_ns };
        self.normalize_cursor();
    }
    pub fn observe(self: *PeerLiveness, id: u64, now_ns: core.TimeNs) PeerLivenessError!?PeerLivenessEvent {
        const peer = self.peer_ptr(id) orelse return error.UnknownPeer;
        if (peer.state == .removed) return error.PeerRemoved;
        if (peer.state == .suspect and now_ns -| peer.suspect_since_ns.? >= self.config.reconnect_window_ns) {
            peer.state = .removed;
            return error.PeerRemoved;
        }
        const event: ?PeerLivenessEvent = if (peer.state == .suspect) .{ .reconnected = id } else null;
        peer.state = .active;
        peer.last_seen_ns = now_ns;
        peer.next_heartbeat_ns = now_ns +| self.config.heartbeat_interval_ns;
        peer.suspect_since_ns = null;
        return event;
    }
    pub fn poll(self: *PeerLiveness, now_ns: core.TimeNs, output: []PeerLivenessEvent) usize {
        const limit = @min(output.len, self.config.maximum_events_per_poll);
        if (limit == 0 or self.peers.items.len == 0) return 0;
        var count: usize = 0;
        var inspected: usize = 0;
        var index = self.cursor;
        while (count < limit and inspected < self.peers.items.len) : (inspected += 1) {
            const peer = &self.peers.items[index];
            if (peer.state == .active and now_ns -| peer.last_seen_ns >= self.config.idle_timeout_ns) {
                peer.state = .suspect;
                peer.suspect_since_ns = now_ns;
                output[count] = .{ .suspect = peer.id };
                count += 1;
            } else if (peer.state == .suspect and now_ns -| peer.suspect_since_ns.? >= self.config.reconnect_window_ns) {
                peer.state = .removed;
                output[count] = .{ .removed = peer.id };
                count += 1;
            } else if (peer.state == .active and now_ns >= peer.next_heartbeat_ns) {
                peer.next_heartbeat_ns = now_ns +| self.config.heartbeat_interval_ns;
                output[count] = .{ .heartbeat = peer.id };
                count += 1;
            }
            index = (index + 1) % self.peers.items.len;
        }
        self.cursor = index;
        return count;
    }
    pub fn state(self: PeerLiveness, id: u64) ?PeerLivenessState {
        const index = self.index_of(id) orelse return null;
        return self.peers.items[index].state;
    }
    fn peer_ptr(self: *PeerLiveness, id: u64) ?*Peer {
        const index = self.index_of(id) orelse return null;
        return &self.peers.items[index];
    }
    fn index_of(self: PeerLiveness, id: u64) ?usize {
        const index = self.insertion_index(id);
        if (index == self.peers.items.len or self.peers.items[index].id != id) return null;
        return index;
    }
    fn insertion_index(self: PeerLiveness, id: u64) usize {
        for (self.peers.items, 0..) |peer, index| if (peer.id >= id) return index;
        return self.peers.items.len;
    }
    fn normalize_cursor(self: *PeerLiveness) void {
        if (self.peers.items.len == 0) self.cursor = 0 else self.cursor %= self.peers.items.len;
    }
};

test "peer liveness emits heartbeats suspects reconnects and removes deterministically" {
    var liveness = try PeerLiveness.init(std.testing.allocator, .{ .maximum_peers = 2, .heartbeat_interval_ns = 5, .idle_timeout_ns = 10, .reconnect_window_ns = 3, .maximum_events_per_poll = 2 });
    defer liveness.deinit();
    try liveness.register(2, 0);
    try liveness.register(1, 0);
    var events: [2]PeerLivenessEvent = undefined;
    try std.testing.expectEqual(@as(usize, 2), liveness.poll(5, events[0..]));
    try std.testing.expectEqual(PeerLivenessEvent{ .heartbeat = 1 }, events[0]);
    try std.testing.expectEqual(PeerLivenessEvent{ .heartbeat = 2 }, events[1]);
    try std.testing.expectEqual(@as(usize, 2), liveness.poll(10, events[0..]));
    try std.testing.expectEqual(PeerLivenessState.suspect, liveness.state(1).?);
    try std.testing.expectEqual(PeerLivenessEvent{ .reconnected = 1 }, (try liveness.observe(1, 11)).?);
    try std.testing.expectEqual(@as(usize, 1), liveness.poll(13, events[0..]));
    try std.testing.expectEqual(PeerLivenessEvent{ .removed = 2 }, events[0]);
    try std.testing.expectEqual(PeerLivenessState.removed, liveness.state(2).?);
}

test "peer liveness rejects invalid capacity duplicate unknown and expired reconnects" {
    var liveness = try PeerLiveness.init(std.testing.allocator, .{ .maximum_peers = 1, .heartbeat_interval_ns = 1, .idle_timeout_ns = 2, .reconnect_window_ns = 1, .maximum_events_per_poll = 1 });
    defer liveness.deinit();
    try liveness.register(1, 0);
    try std.testing.expectError(error.DuplicatePeer, liveness.register(1, 0));
    try std.testing.expectError(error.PeerCapacityExceeded, liveness.register(2, 0));
    try std.testing.expectError(error.UnknownPeer, liveness.observe(2, 0));
    var events: [1]PeerLivenessEvent = undefined;
    _ = liveness.poll(2, events[0..]);
    try std.testing.expectError(error.PeerRemoved, liveness.observe(1, 3));
    try std.testing.expectError(error.InvalidConfiguration, PeerLiveness.init(std.testing.allocator, .{ .maximum_peers = 1, .heartbeat_interval_ns = 3, .idle_timeout_ns = 2, .reconnect_window_ns = 1, .maximum_events_per_poll = 1 }));
}
