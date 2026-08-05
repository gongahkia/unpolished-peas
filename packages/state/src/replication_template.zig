const publisher = @import("snapshot_publisher.zig");
const baseline = @import("snapshot_baseline.zig");

pub const StateReplicationRecipient = u64;
pub const StateReplicationInterestFn = *const fn (?*anyopaque, StateReplicationRecipient, []const u8) bool;
pub const StateReplicationTransportFn = *const fn (?*anyopaque, StateReplicationRecipient, publisher.StateSnapshot) bool;
pub const StateReplicationInterest = struct { context: ?*anyopaque, include: StateReplicationInterestFn };
pub const StateReplicationTransport = struct { context: ?*anyopaque, send: StateReplicationTransportFn };
pub const StateReplicationError = publisher.StateSnapshotError || baseline.StateSnapshotBaselineError || error{ InvalidConfiguration, TransportRejected };
pub const StateReplicationOutcome = union(enum) { filtered, published: publisher.StateSnapshotSequence };
pub const StateReplicationTemplateConfig = struct {
    snapshots: *publisher.StateSnapshotPublisher,
    baselines: ?*baseline.StateSnapshotBaselines = null,
    interest: ?StateReplicationInterest = null,
    transport: ?StateReplicationTransport = null,
};
pub const StateReplicationTemplate = struct {
    config: StateReplicationTemplateConfig,

    pub fn init(config: StateReplicationTemplateConfig) StateReplicationError!StateReplicationTemplate {
        return .{ .config = config };
    }
    pub fn replicate(self: StateReplicationTemplate, recipient: StateReplicationRecipient, state: []const u8) StateReplicationError!StateReplicationOutcome {
        if (recipient == 0) return error.InvalidConfiguration;
        if (self.config.interest) |interest| if (!interest.include(interest.context, recipient, state)) return .filtered;
        const sequence = try self.config.snapshots.publish(state);
        const snapshot = self.config.snapshots.snapshot(sequence).?;
        if (self.config.baselines) |baselines| try baselines.track(snapshot);
        if (self.config.transport) |transport| if (!transport.send(transport.context, recipient, snapshot)) return error.TransportRejected;
        return .{ .published = sequence };
    }
};

test "replication template composes snapshot delta interest and transport opt-ins" {
    const Fixture = struct {
        var sent: usize = 0;
        fn allocate(_: ?*anyopaque, len: usize) ?[*]u8 {
            const bytes = @import("std").testing.allocator.alloc(u8, len) catch return null;
            return bytes.ptr;
        }
        fn release(_: ?*anyopaque, data: [*]u8, len: usize) void {
            @import("std").testing.allocator.free(data[0..len]);
        }
        fn schema(_: ?*anyopaque) u32 {
            return 1;
        }
        fn serialize(_: ?*anyopaque, input: []const u8, version: u32, allocation: @import("serialization_contract.zig").StateSerializationAllocation) @import("serialization_contract.zig").StateSerializationError!@import("serialization_contract.zig").StateSerializationFrame {
            const bytes = try allocation.allocate(input.len);
            @memcpy(bytes, input);
            return .init(version, bytes, allocation);
        }
        fn deterministic(_: ?*anyopaque, first: []const u8, second: []const u8) bool {
            return @import("std").mem.eql(u8, first, second);
        }
        fn failure(_: ?*anyopaque, _: @import("serialization_contract.zig").StateSerializationFailure) void {}
        fn include(_: ?*anyopaque, recipient: StateReplicationRecipient, _: []const u8) bool {
            return recipient == 1;
        }
        fn send(_: ?*anyopaque, _: StateReplicationRecipient, snapshot: publisher.StateSnapshot) bool {
            sent += 1;
            return snapshot.sequence == 0;
        }
    };
    const serialization = @import("serialization_contract.zig");
    const allocation = serialization.StateSerializationAllocation{ .context = null, .allocate_fn = Fixture.allocate, .release_fn = Fixture.release };
    const callbacks = serialization.StateSerializationCallbacks{ .context = null, .schema_version = Fixture.schema, .serialize = Fixture.serialize, .deserialize = Fixture.serialize, .deterministic = Fixture.deterministic, .failure = Fixture.failure };
    const contract = try serialization.StateSerializationContract.init(.{ .maximum_serialized_bytes = 2, .maximum_deserialized_bytes = 2, .allocation = allocation, .callbacks = callbacks });
    var snapshots = try publisher.StateSnapshotPublisher.init(@import("std").testing.allocator, .{ .serialization = contract, .maximum_retained_snapshots = 2, .maximum_subscribers = 1, .maximum_subscriber_metadata_bytes = 0 });
    defer snapshots.deinit();
    var baselines = try baseline.StateSnapshotBaselines.init(@import("std").testing.allocator, .{ .maximum_baselines = 2, .maximum_snapshot_bytes = 2 });
    defer baselines.deinit();
    Fixture.sent = 0;
    const template = try StateReplicationTemplate.init(.{ .snapshots = &snapshots, .baselines = &baselines, .interest = .{ .context = null, .include = Fixture.include }, .transport = .{ .context = null, .send = Fixture.send } });
    try @import("std").testing.expectEqual(StateReplicationOutcome.filtered, try template.replicate(2, "ok"));
    try @import("std").testing.expectEqual(StateReplicationOutcome{ .published = 0 }, try template.replicate(1, "ok"));
    try @import("std").testing.expectEqual(@as(usize, 1), Fixture.sent);
    try @import("std").testing.expect(baselines.select() == null);
}

test "replication template rejects invalid recipients and transport refusal" {
    const Fixture = struct {
        fn allocate(_: ?*anyopaque, len: usize) ?[*]u8 {
            const bytes = @import("std").testing.allocator.alloc(u8, len) catch return null;
            return bytes.ptr;
        }
        fn release(_: ?*anyopaque, data: [*]u8, len: usize) void {
            @import("std").testing.allocator.free(data[0..len]);
        }
        fn schema(_: ?*anyopaque) u32 {
            return 1;
        }
        fn serialize(_: ?*anyopaque, input: []const u8, version: u32, allocation: @import("serialization_contract.zig").StateSerializationAllocation) @import("serialization_contract.zig").StateSerializationError!@import("serialization_contract.zig").StateSerializationFrame {
            const bytes = try allocation.allocate(input.len);
            @memcpy(bytes, input);
            return .init(version, bytes, allocation);
        }
        fn deterministic(_: ?*anyopaque, first: []const u8, second: []const u8) bool {
            return @import("std").mem.eql(u8, first, second);
        }
        fn failure(_: ?*anyopaque, _: @import("serialization_contract.zig").StateSerializationFailure) void {}
        fn reject(_: ?*anyopaque, _: StateReplicationRecipient, _: publisher.StateSnapshot) bool {
            return false;
        }
    };
    const serialization = @import("serialization_contract.zig");
    const allocation = serialization.StateSerializationAllocation{ .context = null, .allocate_fn = Fixture.allocate, .release_fn = Fixture.release };
    const callbacks = serialization.StateSerializationCallbacks{ .context = null, .schema_version = Fixture.schema, .serialize = Fixture.serialize, .deserialize = Fixture.serialize, .deterministic = Fixture.deterministic, .failure = Fixture.failure };
    const contract = try serialization.StateSerializationContract.init(.{ .maximum_serialized_bytes = 2, .maximum_deserialized_bytes = 2, .allocation = allocation, .callbacks = callbacks });
    var snapshots = try publisher.StateSnapshotPublisher.init(@import("std").testing.allocator, .{ .serialization = contract, .maximum_retained_snapshots = 1, .maximum_subscribers = 1, .maximum_subscriber_metadata_bytes = 0 });
    defer snapshots.deinit();
    const template = try StateReplicationTemplate.init(.{ .snapshots = &snapshots, .transport = .{ .context = null, .send = Fixture.reject } });
    try @import("std").testing.expectError(error.InvalidConfiguration, template.replicate(0, "ok"));
    try @import("std").testing.expectError(error.TransportRejected, template.replicate(1, "ok"));
}
