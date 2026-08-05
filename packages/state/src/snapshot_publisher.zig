const std = @import("std");
const core = @import("minna-san-core");
const serialization = @import("serialization_contract.zig");

pub const StateSnapshotSequence = u64;
pub const StateSnapshotSubscriberId = u64;
pub const StateSnapshotError = std.mem.Allocator.Error || serialization.StateSerializationError || error{ InvalidConfiguration, SubscriberCapacityExceeded, DuplicateSubscriber, UnknownSubscriber, MetadataTooLarge, SequenceExhausted };
pub const StateSnapshot = struct {
    sequence: StateSnapshotSequence,
    schema_version: serialization.StateSchemaVersion,
    state: core.BorrowedBuffer,
};
pub const StateSnapshotSubscriber = struct {
    id: StateSnapshotSubscriberId,
    metadata: core.BorrowedBuffer,
    latest_sequence: ?StateSnapshotSequence,
};
pub const StateSnapshotPublisherConfig = struct {
    serialization: serialization.StateSerializationContract,
    maximum_retained_snapshots: usize,
    maximum_subscribers: usize,
    maximum_subscriber_metadata_bytes: usize,
};
const SnapshotRecord = struct {
    sequence: StateSnapshotSequence,
    frame: serialization.StateSerializationFrame,

    fn deinit(self: *SnapshotRecord) void {
        self.frame.deinit();
        self.* = undefined;
    }
};
const SubscriberRecord = struct {
    id: StateSnapshotSubscriberId,
    metadata: core.OwnedBuffer,
    latest_sequence: ?StateSnapshotSequence = null,

    fn deinit(self: *SubscriberRecord) void {
        self.metadata.deinit();
        self.* = undefined;
    }
};
pub const StateSnapshotPublisher = struct {
    allocator: std.mem.Allocator,
    config: StateSnapshotPublisherConfig,
    snapshots: std.ArrayListUnmanaged(SnapshotRecord) = .empty,
    subscribers: std.ArrayListUnmanaged(SubscriberRecord) = .empty,
    next_sequence: StateSnapshotSequence = 0,

    pub fn init(allocator: std.mem.Allocator, config: StateSnapshotPublisherConfig) StateSnapshotError!StateSnapshotPublisher {
        if (config.maximum_retained_snapshots == 0 or config.maximum_subscribers == 0) return error.InvalidConfiguration;
        return .{ .allocator = allocator, .config = config };
    }

    pub fn deinit(self: *StateSnapshotPublisher) void {
        for (self.snapshots.items) |*record| record.deinit();
        self.snapshots.deinit(self.allocator);
        for (self.subscribers.items) |*record| record.deinit();
        self.subscribers.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn register(self: *StateSnapshotPublisher, id: StateSnapshotSubscriberId, metadata: []const u8) StateSnapshotError!void {
        if (id == 0) return error.InvalidConfiguration;
        if (metadata.len > self.config.maximum_subscriber_metadata_bytes) return error.MetadataTooLarge;
        if (self.subscriber_index(id) != null) return error.DuplicateSubscriber;
        if (self.subscribers.items.len == self.config.maximum_subscribers) return error.SubscriberCapacityExceeded;
        try self.subscribers.append(self.allocator, .{ .id = id, .metadata = try core.OwnedBuffer.initCopy(self.allocator, metadata) });
    }

    pub fn unregister(self: *StateSnapshotPublisher, id: StateSnapshotSubscriberId) StateSnapshotError!void {
        const index = self.subscriber_index(id) orelse return error.UnknownSubscriber;
        self.subscribers.items[index].deinit();
        _ = self.subscribers.orderedRemove(index);
    }

    pub fn publish(self: *StateSnapshotPublisher, state: []const u8) StateSnapshotError!StateSnapshotSequence {
        if (self.next_sequence == std.math.maxInt(StateSnapshotSequence)) return error.SequenceExhausted;
        var frame = try self.config.serialization.serialize(state);
        errdefer frame.deinit();
        try self.snapshots.ensureUnusedCapacity(self.allocator, 1);
        if (self.snapshots.items.len == self.config.maximum_retained_snapshots) {
            self.snapshots.items[0].deinit();
            _ = self.snapshots.orderedRemove(0);
        }
        const sequence = self.next_sequence;
        self.next_sequence += 1;
        self.snapshots.appendAssumeCapacity(.{ .sequence = sequence, .frame = frame });
        for (self.subscribers.items) |*record| record.latest_sequence = sequence;
        return sequence;
    }

    pub fn latest(self: *const StateSnapshotPublisher) ?StateSnapshot {
        if (self.snapshots.items.len == 0) return null;
        return self.snapshot_view(self.snapshots.items[self.snapshots.items.len - 1]);
    }

    pub fn snapshot(self: *const StateSnapshotPublisher, sequence: StateSnapshotSequence) ?StateSnapshot {
        for (self.snapshots.items) |record| if (record.sequence == sequence) return self.snapshot_view(record);
        return null;
    }

    pub fn subscriber(self: *const StateSnapshotPublisher, id: StateSnapshotSubscriberId) ?StateSnapshotSubscriber {
        const index = self.subscriber_index(id) orelse return null;
        const value = self.subscribers.items[index];
        return .{ .id = value.id, .metadata = value.metadata.borrow(), .latest_sequence = value.latest_sequence };
    }

    fn snapshot_view(_: *const StateSnapshotPublisher, record: SnapshotRecord) StateSnapshot {
        return .{ .sequence = record.sequence, .schema_version = record.frame.schema_version, .state = .init(record.frame.bytes) };
    }

    fn subscriber_index(self: *const StateSnapshotPublisher, id: StateSnapshotSubscriberId) ?usize {
        for (self.subscribers.items, 0..) |record, index| if (record.id == id) return index;
        return null;
    }
};

test "snapshot publisher retains ordered full snapshots and subscriber metadata" {
    const Fixture = struct {
        fn allocate(_: ?*anyopaque, len: usize) ?[*]u8 {
            const bytes = std.testing.allocator.alloc(u8, len) catch return null;
            return bytes.ptr;
        }
        fn release(_: ?*anyopaque, data: [*]u8, len: usize) void {
            std.testing.allocator.free(data[0..len]);
        }
        fn schema(_: ?*anyopaque) serialization.StateSchemaVersion {
            return 1;
        }
        fn serialize(_: ?*anyopaque, input: []const u8, version: serialization.StateSchemaVersion, allocation: serialization.StateSerializationAllocation) serialization.StateSerializationError!serialization.StateSerializationFrame {
            const bytes = try allocation.allocate(input.len);
            @memcpy(bytes, input);
            return .init(version, bytes, allocation);
        }
        fn deserialize(_: ?*anyopaque, input: []const u8, version: serialization.StateSchemaVersion, allocation: serialization.StateSerializationAllocation) serialization.StateSerializationError!serialization.StateSerializationFrame {
            return serialize(null, input, version, allocation);
        }
        fn deterministic(_: ?*anyopaque, first: []const u8, second: []const u8) bool {
            return std.mem.eql(u8, first, second);
        }
        fn failure(_: ?*anyopaque, _: serialization.StateSerializationFailure) void {}
    };
    const allocation = serialization.StateSerializationAllocation{ .context = null, .allocate_fn = Fixture.allocate, .release_fn = Fixture.release };
    const callbacks = serialization.StateSerializationCallbacks{ .context = null, .schema_version = Fixture.schema, .serialize = Fixture.serialize, .deserialize = Fixture.deserialize, .deterministic = Fixture.deterministic, .failure = Fixture.failure };
    const contract = try serialization.StateSerializationContract.init(.{ .maximum_serialized_bytes = 2, .maximum_deserialized_bytes = 2, .allocation = allocation, .callbacks = callbacks });
    var publisher = try StateSnapshotPublisher.init(std.testing.allocator, .{ .serialization = contract, .maximum_retained_snapshots = 2, .maximum_subscribers = 2, .maximum_subscriber_metadata_bytes = 3 });
    defer publisher.deinit();
    try publisher.register(1, "one");
    try publisher.register(2, "two");
    try std.testing.expectEqual(@as(StateSnapshotSequence, 0), try publisher.publish("a"));
    try std.testing.expectEqual(@as(StateSnapshotSequence, 1), try publisher.publish("b"));
    try std.testing.expectEqual(@as(StateSnapshotSequence, 2), try publisher.publish("c"));
    try std.testing.expect(publisher.snapshot(0) == null);
    const latest = publisher.latest().?;
    try std.testing.expectEqual(@as(StateSnapshotSequence, 2), latest.sequence);
    try std.testing.expectEqualStrings("c", latest.state.bytes);
    const subscriber = publisher.subscriber(1).?;
    try std.testing.expectEqualStrings("one", subscriber.metadata.bytes);
    try std.testing.expectEqual(@as(?StateSnapshotSequence, 2), subscriber.latest_sequence);
}

test "snapshot publisher rejects invalid capacity metadata and serialization inputs" {
    const Fixture = struct {
        fn allocate(_: ?*anyopaque, len: usize) ?[*]u8 {
            const bytes = std.testing.allocator.alloc(u8, len) catch return null;
            return bytes.ptr;
        }
        fn release(_: ?*anyopaque, data: [*]u8, len: usize) void {
            std.testing.allocator.free(data[0..len]);
        }
        fn schema(_: ?*anyopaque) serialization.StateSchemaVersion {
            return 1;
        }
        fn serialize(_: ?*anyopaque, input: []const u8, version: serialization.StateSchemaVersion, allocation: serialization.StateSerializationAllocation) serialization.StateSerializationError!serialization.StateSerializationFrame {
            if (std.mem.eql(u8, input, "bad")) return error.SerializationFailed;
            const bytes = try allocation.allocate(input.len);
            @memcpy(bytes, input);
            return .init(version, bytes, allocation);
        }
        fn deserialize(_: ?*anyopaque, input: []const u8, version: serialization.StateSchemaVersion, allocation: serialization.StateSerializationAllocation) serialization.StateSerializationError!serialization.StateSerializationFrame {
            return serialize(null, input, version, allocation);
        }
        fn deterministic(_: ?*anyopaque, first: []const u8, second: []const u8) bool {
            return std.mem.eql(u8, first, second);
        }
        fn failure(_: ?*anyopaque, _: serialization.StateSerializationFailure) void {}
    };
    const allocation = serialization.StateSerializationAllocation{ .context = null, .allocate_fn = Fixture.allocate, .release_fn = Fixture.release };
    const callbacks = serialization.StateSerializationCallbacks{ .context = null, .schema_version = Fixture.schema, .serialize = Fixture.serialize, .deserialize = Fixture.deserialize, .deterministic = Fixture.deterministic, .failure = Fixture.failure };
    const contract = try serialization.StateSerializationContract.init(.{ .maximum_serialized_bytes = 2, .maximum_deserialized_bytes = 2, .allocation = allocation, .callbacks = callbacks });
    try std.testing.expectError(error.InvalidConfiguration, StateSnapshotPublisher.init(std.testing.allocator, .{ .serialization = contract, .maximum_retained_snapshots = 0, .maximum_subscribers = 1, .maximum_subscriber_metadata_bytes = 1 }));
    var publisher = try StateSnapshotPublisher.init(std.testing.allocator, .{ .serialization = contract, .maximum_retained_snapshots = 1, .maximum_subscribers = 1, .maximum_subscriber_metadata_bytes = 1 });
    defer publisher.deinit();
    try std.testing.expectError(error.InvalidConfiguration, publisher.register(0, ""));
    try std.testing.expectError(error.MetadataTooLarge, publisher.register(1, "xx"));
    try publisher.register(1, "x");
    try std.testing.expectError(error.DuplicateSubscriber, publisher.register(1, "x"));
    try std.testing.expectError(error.SubscriberCapacityExceeded, publisher.register(2, "x"));
    try std.testing.expectError(error.SerializationFailed, publisher.publish("bad"));
    try std.testing.expectError(error.UnknownSubscriber, publisher.unregister(2));
}
