const core = @import("minna-san-core");
const template = @import("replication_template.zig");

pub const StateAuthoritativeStateFn = *const fn (?*anyopaque, template.StateReplicationRecipient) ?core.BorrowedBuffer;
pub const StateAuthoritativeReplicationError = template.StateReplicationError || error{ InvalidConfiguration, StateUnavailable };
pub const StateAuthoritativeReplicationConfig = struct {
    replication: template.StateReplicationTemplate,
    state_context: ?*anyopaque,
    state: StateAuthoritativeStateFn,
};
pub const StateAuthoritativeReplication = struct {
    config: StateAuthoritativeReplicationConfig,

    pub fn init(config: StateAuthoritativeReplicationConfig) StateAuthoritativeReplicationError!StateAuthoritativeReplication {
        return .{ .config = config };
    }
    pub fn publish(self: StateAuthoritativeReplication, recipient: template.StateReplicationRecipient) StateAuthoritativeReplicationError!template.StateReplicationOutcome {
        const state = self.config.state(self.config.state_context, recipient) orelse return error.StateUnavailable;
        return self.config.replication.replicate(recipient, state.bytes);
    }
};

test "authoritative replication publishes consumer-supplied server state" {
    const Fixture = struct {
        var sends: usize = 0;
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
        fn state(_: ?*anyopaque, recipient: template.StateReplicationRecipient) ?core.BorrowedBuffer {
            return if (recipient == 1) .init("ok") else null;
        }
        fn send(_: ?*anyopaque, _: template.StateReplicationRecipient, _: @import("snapshot_publisher.zig").StateSnapshot) bool {
            sends += 1;
            return true;
        }
    };
    const serialization = @import("serialization_contract.zig");
    const snapshots = @import("snapshot_publisher.zig");
    const allocation = serialization.StateSerializationAllocation{ .context = null, .allocate_fn = Fixture.allocate, .release_fn = Fixture.release };
    const callbacks = serialization.StateSerializationCallbacks{ .context = null, .schema_version = Fixture.schema, .serialize = Fixture.serialize, .deserialize = Fixture.serialize, .deterministic = Fixture.deterministic, .failure = Fixture.failure };
    const contract = try serialization.StateSerializationContract.init(.{ .maximum_serialized_bytes = 2, .maximum_deserialized_bytes = 2, .allocation = allocation, .callbacks = callbacks });
    var publisher = try snapshots.StateSnapshotPublisher.init(@import("std").testing.allocator, .{ .serialization = contract, .maximum_retained_snapshots = 1, .maximum_subscribers = 1, .maximum_subscriber_metadata_bytes = 0 });
    defer publisher.deinit();
    Fixture.sends = 0;
    const replication = try template.StateReplicationTemplate.init(.{ .snapshots = &publisher, .transport = .{ .context = null, .send = Fixture.send } });
    const authoritative = try StateAuthoritativeReplication.init(.{ .replication = replication, .state_context = null, .state = Fixture.state });
    try @import("std").testing.expectEqual(template.StateReplicationOutcome{ .published = 0 }, try authoritative.publish(1));
    try @import("std").testing.expectEqual(@as(usize, 1), Fixture.sends);
    try @import("std").testing.expectError(error.StateUnavailable, authoritative.publish(2));
}
