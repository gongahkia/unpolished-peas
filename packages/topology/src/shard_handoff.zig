const std = @import("std");
const directory = @import("shard_directory.zig");

pub const HandoffClientId = u64;
pub const ShardHandoffId = u64;

pub const ShardHandoffRequest = struct {
    client: HandoffClientId,
    source: directory.ShardId,
    destination: directory.ShardId,
    state_revision: u64,
    state: []const u8,
};

pub const ShardHandoff = struct {
    id: ShardHandoffId,
    client: HandoffClientId,
    source: directory.ShardId,
    destination: directory.ShardId,
    state_revision: u64,
    state: []const u8,
};

pub const ShardHandoffError = std.mem.Allocator.Error || directory.ShardDirectoryError || error{ InvalidConfiguration, InvalidRequest, PendingCapacityExceeded, StateTooLarge, ClientAlreadyPending, UnknownHandoff, UnhealthyShard, InsufficientCapacity, StateRevisionMismatch };

pub const ShardHandoffConfig = struct {
    maximum_pending_handoffs: usize,
    maximum_state_bytes: usize,
};

const StoredHandoff = struct {
    id: ShardHandoffId,
    client: HandoffClientId,
    source: directory.ShardId,
    destination: directory.ShardId,
    state_revision: u64,
    state: []u8,

    fn view(self: StoredHandoff) ShardHandoff {
        return .{
            .id = self.id,
            .client = self.client,
            .source = self.source,
            .destination = self.destination,
            .state_revision = self.state_revision,
            .state = self.state,
        };
    }
};

pub const ShardHandoffCoordinator = struct {
    allocator: std.mem.Allocator,
    directory: *directory.ShardDirectory,
    config: ShardHandoffConfig,
    pending: std.ArrayListUnmanaged(StoredHandoff) = .empty,
    next_id: ShardHandoffId = 1,

    pub fn init(allocator: std.mem.Allocator, shard_directory: *directory.ShardDirectory, config: ShardHandoffConfig) ShardHandoffError!ShardHandoffCoordinator {
        if (config.maximum_pending_handoffs == 0) return error.InvalidConfiguration;
        return .{ .allocator = allocator, .directory = shard_directory, .config = config };
    }

    pub fn deinit(self: *ShardHandoffCoordinator) void {
        for (self.pending.items) |record| self.allocator.free(record.state);
        self.pending.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn pending_count(self: ShardHandoffCoordinator) usize {
        return self.pending.items.len;
    }

    pub fn prepare(self: *ShardHandoffCoordinator, request: ShardHandoffRequest) ShardHandoffError!ShardHandoffId {
        try self.validate_request(request);
        if (self.client_index(request.client) != null) return error.ClientAlreadyPending;
        if (self.pending.items.len == self.config.maximum_pending_handoffs) return error.PendingCapacityExceeded;
        const id = self.next_id;
        const next_id = std.math.add(ShardHandoffId, id, 1) catch return error.PendingCapacityExceeded;
        const source = self.directory.lookup(request.source) orelse return error.UnknownShard;
        const destination = self.directory.lookup(request.destination) orelse return error.UnknownShard;
        if (source.health != .healthy or destination.health != .healthy) return error.UnhealthyShard;
        if (source.capacity.active_participants == 0 or destination.capacity.available() == 0) return error.InsufficientCapacity;
        try self.pending.ensureUnusedCapacity(self.allocator, 1);
        const state = try self.allocator.dupe(u8, request.state);
        errdefer self.allocator.free(state);
        try self.directory.set_active_participants(request.destination, destination.capacity.active_participants + 1);
        self.pending.appendAssumeCapacity(.{
            .id = id,
            .client = request.client,
            .source = request.source,
            .destination = request.destination,
            .state_revision = request.state_revision,
            .state = state,
        });
        self.next_id = next_id;
        return id;
    }

    pub fn handoff(self: ShardHandoffCoordinator, id: ShardHandoffId) ShardHandoffError!ShardHandoff {
        const index = self.index_of(id) orelse return error.UnknownHandoff;
        return self.pending.items[index].view();
    }

    pub fn acknowledge(self: *ShardHandoffCoordinator, id: ShardHandoffId, state_revision: u64) ShardHandoffError!void {
        const index = self.index_of(id) orelse return error.UnknownHandoff;
        const record = self.pending.items[index];
        if (record.state_revision != state_revision) return error.StateRevisionMismatch;
        const source = self.directory.lookup(record.source) orelse return error.UnknownShard;
        if (source.capacity.active_participants == 0) return error.InsufficientCapacity;
        try self.directory.set_active_participants(record.source, source.capacity.active_participants - 1);
        self.remove_pending(index);
    }

    pub fn rollback(self: *ShardHandoffCoordinator, id: ShardHandoffId) ShardHandoffError!void {
        const index = self.index_of(id) orelse return error.UnknownHandoff;
        const record = self.pending.items[index];
        const destination = self.directory.lookup(record.destination) orelse return error.UnknownShard;
        if (destination.capacity.active_participants == 0) return error.InsufficientCapacity;
        try self.directory.set_active_participants(record.destination, destination.capacity.active_participants - 1);
        self.remove_pending(index);
    }

    fn validate_request(self: ShardHandoffCoordinator, request: ShardHandoffRequest) ShardHandoffError!void {
        if (request.client == 0 or request.source == 0 or request.destination == 0 or request.source == request.destination) return error.InvalidRequest;
        if (request.state.len > self.config.maximum_state_bytes) return error.StateTooLarge;
    }

    fn index_of(self: ShardHandoffCoordinator, id: ShardHandoffId) ?usize {
        if (id == 0) return null;
        for (self.pending.items, 0..) |record, index| if (record.id == id) return index;
        return null;
    }

    fn client_index(self: ShardHandoffCoordinator, client: HandoffClientId) ?usize {
        for (self.pending.items, 0..) |record, index| if (record.client == client) return index;
        return null;
    }

    fn remove_pending(self: *ShardHandoffCoordinator, index: usize) void {
        const record = self.pending.orderedRemove(index);
        self.allocator.free(record.state);
    }
};

fn registration(id: directory.ShardId, active: usize) directory.ShardRegistration {
    return .{
        .id = id,
        .capacity = .{ .maximum_participants = 3, .active_participants = active },
        .health = .healthy,
        .route = .{ .id = id, .kind = .authoritative, .endpoint = directory.ShardEndpoint.from_ipv4(.{ .octets = .{ 127, 0, 0, @intCast(id) }, .port = 9000 }) },
    };
}

test "shard handoff reserves capacity transfers state and acknowledges atomically" {
    var shard_directory = try directory.ShardDirectory.init(std.testing.allocator, .{ .maximum_shards = 2 });
    defer shard_directory.deinit();
    try shard_directory.register(registration(1, 1));
    try shard_directory.register(registration(2, 0));
    var coordinator = try ShardHandoffCoordinator.init(std.testing.allocator, &shard_directory, .{ .maximum_pending_handoffs = 2, .maximum_state_bytes = 8 });
    defer coordinator.deinit();
    const first = try coordinator.prepare(.{ .client = 7, .source = 1, .destination = 2, .state_revision = 4, .state = "state" });
    try std.testing.expectEqual(@as(usize, 1), coordinator.pending_count());
    try std.testing.expectEqual(@as(usize, 2), try shard_directory.available_capacity(2));
    const prepared = try coordinator.handoff(first);
    try std.testing.expectEqual(@as(HandoffClientId, 7), prepared.client);
    try std.testing.expectEqualStrings("state", prepared.state);
    try coordinator.acknowledge(first, 4);
    try std.testing.expectEqual(@as(usize, 0), coordinator.pending_count());
    try std.testing.expectEqual(@as(usize, 3), try shard_directory.available_capacity(1));
    try std.testing.expectEqual(@as(usize, 2), try shard_directory.available_capacity(2));
    try shard_directory.set_active_participants(1, 1);
    const second = try coordinator.prepare(.{ .client = 8, .source = 1, .destination = 2, .state_revision = 5, .state = "next" });
    try std.testing.expectEqual(@as(usize, 1), try shard_directory.available_capacity(2));
    try coordinator.rollback(second);
    try std.testing.expectEqual(@as(usize, 2), try shard_directory.available_capacity(2));
    try std.testing.expectError(error.UnknownHandoff, coordinator.handoff(second));
}

test "shard handoff preserves reservations across rejected acknowledgements and requests" {
    try std.testing.expectError(error.InvalidConfiguration, ShardHandoffCoordinator.init(std.testing.allocator, undefined, .{ .maximum_pending_handoffs = 0, .maximum_state_bytes = 1 }));
    var shard_directory = try directory.ShardDirectory.init(std.testing.allocator, .{ .maximum_shards = 2 });
    defer shard_directory.deinit();
    try shard_directory.register(registration(1, 1));
    try shard_directory.register(registration(2, 0));
    var coordinator = try ShardHandoffCoordinator.init(std.testing.allocator, &shard_directory, .{ .maximum_pending_handoffs = 1, .maximum_state_bytes = 3 });
    defer coordinator.deinit();
    try std.testing.expectError(error.InvalidRequest, coordinator.prepare(.{ .client = 0, .source = 1, .destination = 2, .state_revision = 1, .state = "" }));
    try std.testing.expectError(error.StateTooLarge, coordinator.prepare(.{ .client = 1, .source = 1, .destination = 2, .state_revision = 1, .state = "long" }));
    const handoff = try coordinator.prepare(.{ .client = 1, .source = 1, .destination = 2, .state_revision = 1, .state = "ok" });
    try std.testing.expectError(error.ClientAlreadyPending, coordinator.prepare(.{ .client = 1, .source = 1, .destination = 2, .state_revision = 1, .state = "ok" }));
    try std.testing.expectError(error.PendingCapacityExceeded, coordinator.prepare(.{ .client = 2, .source = 1, .destination = 2, .state_revision = 1, .state = "ok" }));
    try std.testing.expectError(error.StateRevisionMismatch, coordinator.acknowledge(handoff, 2));
    try std.testing.expectEqual(@as(usize, 1), coordinator.pending_count());
    try std.testing.expectEqual(@as(usize, 2), try shard_directory.available_capacity(2));
    try coordinator.rollback(handoff);
    try std.testing.expectEqual(@as(usize, 3), try shard_directory.available_capacity(2));
    try shard_directory.set_health(2, .unavailable);
    try std.testing.expectError(error.UnhealthyShard, coordinator.prepare(.{ .client = 2, .source = 1, .destination = 2, .state_revision = 1, .state = "ok" }));
}
