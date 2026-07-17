const std = @import("std");
const core = @import("minna-san-core");
const serialization = @import("serialization_contract.zig");
const decoder = @import("state_decoder.zig");
const publisher = @import("snapshot_publisher.zig");

pub const StateSnapshotDelivery = struct {
    sequence: publisher.StateSnapshotSequence,
    schema_version: serialization.StateSchemaVersion,
    state: core.BorrowedBuffer,
    expires_at_ns: core.TimeNs,
};
pub const StateSnapshotApplied = struct {
    sequence: publisher.StateSnapshotSequence,
    state: core.BorrowedBuffer,
};
pub const StateSnapshotApplyFn = *const fn (?*anyopaque, StateSnapshotApplied) bool;
pub const StateSnapshotClientError = decoder.StateDecodeError || error{ InvalidConfiguration, SnapshotExpired, StaleSnapshot, OutOfOrderSnapshot, SnapshotTooLarge, ApplicationRejected, SequenceExhausted };
pub const StateSnapshotClientConfig = struct {
    decoder: decoder.StateDecoder,
    maximum_snapshot_bytes: usize,
    application_context: ?*anyopaque,
    apply: StateSnapshotApplyFn,
};
pub const StateSnapshotClient = struct {
    config: StateSnapshotClientConfig,
    next_sequence: publisher.StateSnapshotSequence = 0,

    pub fn init(config: StateSnapshotClientConfig) StateSnapshotClientError!StateSnapshotClient {
        if (config.maximum_snapshot_bytes == 0) return error.InvalidConfiguration;
        return .{ .config = config };
    }

    pub fn consume(self: *StateSnapshotClient, delivery: StateSnapshotDelivery, now_ns: core.TimeNs) StateSnapshotClientError!void {
        if (delivery.expires_at_ns < now_ns) return error.SnapshotExpired;
        if (delivery.sequence < self.next_sequence) return error.StaleSnapshot;
        if (delivery.sequence > self.next_sequence) return error.OutOfOrderSnapshot;
        if (delivery.sequence == std.math.maxInt(publisher.StateSnapshotSequence)) return error.SequenceExhausted;
        if (delivery.state.bytes.len > self.config.maximum_snapshot_bytes) return error.SnapshotTooLarge;
        const allocation = self.config.decoder.config.serialization.config.allocation;
        const input_bytes = try allocation.allocate(delivery.state.bytes.len);
        @memcpy(input_bytes, delivery.state.bytes);
        var input = serialization.StateSerializationFrame.init(delivery.schema_version, input_bytes, allocation);
        defer input.deinit();
        var output = try self.config.decoder.decode(&input);
        defer output.deinit();
        if (!self.config.apply(self.config.application_context, .{ .sequence = delivery.sequence, .state = .init(output.bytes) })) return error.ApplicationRejected;
        self.next_sequence += 1;
    }
};

test "snapshot client applies copied ordered nonexpired snapshots" {
    const Fixture = struct {
        var applied_sequence: u64 = 0;
        var applied: [2]u8 = undefined;
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
        fn serialization_failure(_: ?*anyopaque, _: serialization.StateSerializationFailure) void {}
        fn compatible(_: ?*anyopaque, source: serialization.StateSchemaVersion, current: serialization.StateSchemaVersion) bool {
            return source == current;
        }
        fn decode_failure(_: ?*anyopaque, _: decoder.StateDecodeFailure) void {}
        fn apply(_: ?*anyopaque, event: StateSnapshotApplied) bool {
            applied_sequence = event.sequence;
            @memcpy(&applied, event.state.bytes);
            return true;
        }
    };
    const allocation = serialization.StateSerializationAllocation{ .context = null, .allocate_fn = Fixture.allocate, .release_fn = Fixture.release };
    const callbacks = serialization.StateSerializationCallbacks{ .context = null, .schema_version = Fixture.schema, .serialize = Fixture.serialize, .deserialize = Fixture.deserialize, .deterministic = Fixture.deterministic, .failure = Fixture.serialization_failure };
    const contract = try serialization.StateSerializationContract.init(.{ .maximum_serialized_bytes = 2, .maximum_deserialized_bytes = 2, .allocation = allocation, .callbacks = callbacks });
    const state_decoder = try decoder.StateDecoder.init(.{ .serialization = contract, .compatibility_context = null, .compatible = Fixture.compatible, .failure_context = null, .failure = Fixture.decode_failure });
    var client = try StateSnapshotClient.init(.{ .decoder = state_decoder, .maximum_snapshot_bytes = 2, .application_context = null, .apply = Fixture.apply });
    Fixture.applied_sequence = 99;
    try client.consume(.{ .sequence = 0, .schema_version = 1, .state = .init("ok"), .expires_at_ns = 2 }, 1);
    try std.testing.expectEqual(@as(u64, 0), Fixture.applied_sequence);
    try std.testing.expectEqualStrings("ok", &Fixture.applied);
}

test "snapshot client rejects expired unordered oversized and refused state" {
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
        fn serialization_failure(_: ?*anyopaque, _: serialization.StateSerializationFailure) void {}
        fn compatible(_: ?*anyopaque, source: serialization.StateSchemaVersion, current: serialization.StateSchemaVersion) bool {
            return source == current;
        }
        fn decode_failure(_: ?*anyopaque, _: decoder.StateDecodeFailure) void {}
        fn reject(_: ?*anyopaque, _: StateSnapshotApplied) bool {
            return false;
        }
    };
    const allocation = serialization.StateSerializationAllocation{ .context = null, .allocate_fn = Fixture.allocate, .release_fn = Fixture.release };
    const callbacks = serialization.StateSerializationCallbacks{ .context = null, .schema_version = Fixture.schema, .serialize = Fixture.serialize, .deserialize = Fixture.deserialize, .deterministic = Fixture.deterministic, .failure = Fixture.serialization_failure };
    const contract = try serialization.StateSerializationContract.init(.{ .maximum_serialized_bytes = 2, .maximum_deserialized_bytes = 2, .allocation = allocation, .callbacks = callbacks });
    const state_decoder = try decoder.StateDecoder.init(.{ .serialization = contract, .compatibility_context = null, .compatible = Fixture.compatible, .failure_context = null, .failure = Fixture.decode_failure });
    var client = try StateSnapshotClient.init(.{ .decoder = state_decoder, .maximum_snapshot_bytes = 2, .application_context = null, .apply = Fixture.reject });
    try std.testing.expectError(error.SnapshotExpired, client.consume(.{ .sequence = 0, .schema_version = 1, .state = .init("ok"), .expires_at_ns = 0 }, 1));
    try std.testing.expectError(error.OutOfOrderSnapshot, client.consume(.{ .sequence = 1, .schema_version = 1, .state = .init("ok"), .expires_at_ns = 1 }, 1));
    try std.testing.expectError(error.SnapshotTooLarge, client.consume(.{ .sequence = 0, .schema_version = 1, .state = .init("big"), .expires_at_ns = 1 }, 1));
    try std.testing.expectError(error.ApplicationRejected, client.consume(.{ .sequence = 0, .schema_version = 1, .state = .init("ok"), .expires_at_ns = 1 }, 1));
}
