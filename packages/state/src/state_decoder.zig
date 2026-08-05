const std = @import("std");
const serialization = @import("serialization_contract.zig");

pub const StateDecodeFailure = enum {
    schema_incompatible,
    deserialization,
};
pub const StateDecodeError = serialization.StateSerializationError || error{ InvalidConfiguration, SchemaIncompatible };
pub const StateSchemaCompatibilityFn = *const fn (?*anyopaque, serialization.StateSchemaVersion, serialization.StateSchemaVersion) bool;
pub const StateDecodeFailureFn = *const fn (?*anyopaque, StateDecodeFailure) void;
pub const StateDecoderConfig = struct {
    serialization: serialization.StateSerializationContract,
    compatibility_context: ?*anyopaque,
    compatible: StateSchemaCompatibilityFn,
    failure_context: ?*anyopaque,
    failure: StateDecodeFailureFn,
};
pub const StateDecoder = struct {
    config: StateDecoderConfig,

    pub fn init(config: StateDecoderConfig) StateDecodeError!StateDecoder {
        return .{ .config = config };
    }

    pub fn decode(self: StateDecoder, frame: *const serialization.StateSerializationFrame) StateDecodeError!serialization.StateSerializationFrame {
        const current_version = try self.config.serialization.schema_version();
        if (!self.config.compatible(self.config.compatibility_context, frame.schema_version, current_version)) {
            self.report(.schema_incompatible);
            return error.SchemaIncompatible;
        }
        return self.config.serialization.deserialize_compatible(frame) catch |err| {
            self.report(.deserialization);
            return err;
        };
    }

    fn report(self: StateDecoder, failure: StateDecodeFailure) void {
        self.config.failure(self.config.failure_context, failure);
    }
};

test "state decoder borrows compatible source frames and returns caller-owned state" {
    const Fixture = struct {
        var failures: usize = 0;
        var decoded_version: serialization.StateSchemaVersion = 0;

        fn allocate(_: ?*anyopaque, len: usize) ?[*]u8 {
            const bytes = std.testing.allocator.alloc(u8, len) catch return null;
            return bytes.ptr;
        }
        fn release(_: ?*anyopaque, data: [*]u8, len: usize) void {
            std.testing.allocator.free(data[0..len]);
        }
        fn schema_version(_: ?*anyopaque) serialization.StateSchemaVersion {
            return 2;
        }
        fn serialize(_: ?*anyopaque, input: []const u8, version: serialization.StateSchemaVersion, allocation: serialization.StateSerializationAllocation) serialization.StateSerializationError!serialization.StateSerializationFrame {
            const bytes = try allocation.allocate(input.len);
            @memcpy(bytes, input);
            return .init(version, bytes, allocation);
        }
        fn deserialize(_: ?*anyopaque, input: []const u8, version: serialization.StateSchemaVersion, allocation: serialization.StateSerializationAllocation) serialization.StateSerializationError!serialization.StateSerializationFrame {
            decoded_version = version;
            const bytes = try allocation.allocate(input.len);
            @memcpy(bytes, input);
            return .init(2, bytes, allocation);
        }
        fn deterministic(_: ?*anyopaque, first: []const u8, second: []const u8) bool {
            return std.mem.eql(u8, first, second);
        }
        fn serialization_failure(_: ?*anyopaque, _: serialization.StateSerializationFailure) void {}
        fn compatible(_: ?*anyopaque, source: serialization.StateSchemaVersion, current: serialization.StateSchemaVersion) bool {
            return source <= current;
        }
        fn decode_failure(_: ?*anyopaque, _: StateDecodeFailure) void {
            failures += 1;
        }
    };
    Fixture.failures = 0;
    Fixture.decoded_version = 0;
    const allocation = serialization.StateSerializationAllocation{ .context = null, .allocate_fn = Fixture.allocate, .release_fn = Fixture.release };
    const callbacks = serialization.StateSerializationCallbacks{ .context = null, .schema_version = Fixture.schema_version, .serialize = Fixture.serialize, .deserialize = Fixture.deserialize, .deterministic = Fixture.deterministic, .failure = Fixture.serialization_failure };
    const contract = try serialization.StateSerializationContract.init(.{ .maximum_serialized_bytes = 4, .maximum_deserialized_bytes = 4, .allocation = allocation, .callbacks = callbacks });
    const decoder = try StateDecoder.init(.{ .serialization = contract, .compatibility_context = null, .compatible = Fixture.compatible, .failure_context = null, .failure = Fixture.decode_failure });
    const source_bytes = try allocation.allocate(4);
    @memcpy(source_bytes, "v1ok");
    var source = serialization.StateSerializationFrame.init(1, source_bytes, allocation);
    defer source.deinit();
    var decoded = try decoder.decode(&source);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(serialization.StateSchemaVersion, 1), Fixture.decoded_version);
    try std.testing.expectEqualStrings("v1ok", source.bytes);
    try std.testing.expectEqual(@as(serialization.StateSchemaVersion, 2), decoded.schema_version);
    try std.testing.expectEqualStrings("v1ok", decoded.bytes);
    try std.testing.expectEqual(@as(usize, 0), Fixture.failures);
}

test "state decoder classifies incompatible schemas and consumer decoder failures" {
    const Fixture = struct {
        var failures: [2]StateDecodeFailure = undefined;
        var failure_count: usize = 0;
        var deserialize_fails: bool = false;

        fn allocate(_: ?*anyopaque, len: usize) ?[*]u8 {
            const bytes = std.testing.allocator.alloc(u8, len) catch return null;
            return bytes.ptr;
        }
        fn release(_: ?*anyopaque, data: [*]u8, len: usize) void {
            std.testing.allocator.free(data[0..len]);
        }
        fn schema_version(_: ?*anyopaque) serialization.StateSchemaVersion {
            return 2;
        }
        fn serialize(_: ?*anyopaque, input: []const u8, version: serialization.StateSchemaVersion, allocation: serialization.StateSerializationAllocation) serialization.StateSerializationError!serialization.StateSerializationFrame {
            const bytes = try allocation.allocate(input.len);
            @memcpy(bytes, input);
            return .init(version, bytes, allocation);
        }
        fn deserialize(_: ?*anyopaque, input: []const u8, version: serialization.StateSchemaVersion, allocation: serialization.StateSerializationAllocation) serialization.StateSerializationError!serialization.StateSerializationFrame {
            if (deserialize_fails) return error.DeserializationFailed;
            const bytes = try allocation.allocate(input.len);
            @memcpy(bytes, input);
            return .init(version, bytes, allocation);
        }
        fn deterministic(_: ?*anyopaque, first: []const u8, second: []const u8) bool {
            return std.mem.eql(u8, first, second);
        }
        fn serialization_failure(_: ?*anyopaque, _: serialization.StateSerializationFailure) void {}
        fn compatible(_: ?*anyopaque, source: serialization.StateSchemaVersion, current: serialization.StateSchemaVersion) bool {
            return source == current;
        }
        fn decode_failure(_: ?*anyopaque, failure: StateDecodeFailure) void {
            failures[failure_count] = failure;
            failure_count += 1;
        }
    };
    Fixture.failure_count = 0;
    Fixture.deserialize_fails = false;
    const allocation = serialization.StateSerializationAllocation{ .context = null, .allocate_fn = Fixture.allocate, .release_fn = Fixture.release };
    const callbacks = serialization.StateSerializationCallbacks{ .context = null, .schema_version = Fixture.schema_version, .serialize = Fixture.serialize, .deserialize = Fixture.deserialize, .deterministic = Fixture.deterministic, .failure = Fixture.serialization_failure };
    const contract = try serialization.StateSerializationContract.init(.{ .maximum_serialized_bytes = 2, .maximum_deserialized_bytes = 2, .allocation = allocation, .callbacks = callbacks });
    const decoder = try StateDecoder.init(.{ .serialization = contract, .compatibility_context = null, .compatible = Fixture.compatible, .failure_context = null, .failure = Fixture.decode_failure });
    const source_bytes = try allocation.allocate(2);
    @memcpy(source_bytes, "ok");
    var source = serialization.StateSerializationFrame.init(1, source_bytes, allocation);
    defer source.deinit();
    try std.testing.expectError(error.SchemaIncompatible, decoder.decode(&source));
    source.schema_version = 2;
    Fixture.deserialize_fails = true;
    try std.testing.expectError(error.DeserializationFailed, decoder.decode(&source));
    try std.testing.expectEqualSlices(StateDecodeFailure, &.{ .schema_incompatible, .deserialization }, Fixture.failures[0..Fixture.failure_count]);
}
