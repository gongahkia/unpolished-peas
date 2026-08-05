const std = @import("std");

pub const StateSchemaVersion = u32;
pub const StateSerializationFailure = enum {
    invalid_configuration,
    invalid_schema_version,
    schema_version_mismatch,
    allocation_failed,
    serialization_failed,
    deserialization_failed,
    serialized_output_too_large,
    deserialized_output_too_large,
    allocation_mismatch,
    non_deterministic,
};
pub const StateSerializationError = error{
    InvalidConfiguration,
    InvalidSchemaVersion,
    SchemaVersionMismatch,
    AllocationFailed,
    SerializationFailed,
    DeserializationFailed,
    SerializedOutputTooLarge,
    DeserializedOutputTooLarge,
    AllocationMismatch,
    NonDeterministic,
};
pub const StateSerializationAllocateFn = *const fn (?*anyopaque, usize) ?[*]u8;
pub const StateSerializationReleaseFn = *const fn (?*anyopaque, [*]u8, usize) void;
pub const StateSerializationAllocation = struct {
    context: ?*anyopaque,
    allocate_fn: StateSerializationAllocateFn,
    release_fn: StateSerializationReleaseFn,

    pub fn allocate(self: StateSerializationAllocation, len: usize) StateSerializationError![]u8 {
        const data = self.allocate_fn(self.context, len) orelse return error.AllocationFailed;
        return data[0..len];
    }

    pub fn release(self: StateSerializationAllocation, bytes: []u8) void {
        self.release_fn(self.context, bytes.ptr, bytes.len);
    }

    pub fn eql(left: StateSerializationAllocation, right: StateSerializationAllocation) bool {
        return left.context == right.context and @intFromPtr(left.allocate_fn) == @intFromPtr(right.allocate_fn) and @intFromPtr(left.release_fn) == @intFromPtr(right.release_fn);
    }
};
pub const StateSerializationFrame = struct {
    schema_version: StateSchemaVersion,
    bytes: []u8,
    allocation: StateSerializationAllocation,

    pub fn init(schema_version: StateSchemaVersion, bytes: []u8, allocation: StateSerializationAllocation) StateSerializationFrame {
        return .{ .schema_version = schema_version, .bytes = bytes, .allocation = allocation };
    }

    pub fn deinit(self: *StateSerializationFrame) void {
        self.allocation.release(self.bytes);
        self.* = undefined;
    }
};
pub const StateSchemaVersionFn = *const fn (?*anyopaque) StateSchemaVersion;
pub const StateSerializeFn = *const fn (?*anyopaque, []const u8, StateSchemaVersion, StateSerializationAllocation) StateSerializationError!StateSerializationFrame;
pub const StateDeserializeFn = *const fn (?*anyopaque, []const u8, StateSchemaVersion, StateSerializationAllocation) StateSerializationError!StateSerializationFrame;
pub const StateSerializationDeterminismFn = *const fn (?*anyopaque, []const u8, []const u8) bool;
pub const StateSerializationFailureFn = *const fn (?*anyopaque, StateSerializationFailure) void;
pub const StateSerializationCallbacks = struct {
    context: ?*anyopaque,
    schema_version: StateSchemaVersionFn,
    serialize: StateSerializeFn,
    deserialize: StateDeserializeFn,
    deterministic: StateSerializationDeterminismFn,
    failure: StateSerializationFailureFn,
};
pub const StateSerializationConfig = struct {
    maximum_serialized_bytes: usize,
    maximum_deserialized_bytes: usize,
    allocation: StateSerializationAllocation,
    callbacks: StateSerializationCallbacks,
};
pub const StateSerializationContract = struct {
    config: StateSerializationConfig,

    pub fn init(config: StateSerializationConfig) StateSerializationError!StateSerializationContract {
        if (config.maximum_serialized_bytes == 0 or config.maximum_deserialized_bytes == 0) return error.InvalidConfiguration;
        return .{ .config = config };
    }

    pub fn schema_version(self: StateSerializationContract) StateSerializationError!StateSchemaVersion {
        const version = self.config.callbacks.schema_version(self.config.callbacks.context);
        if (version == 0) {
            self.report(.invalid_schema_version);
            return error.InvalidSchemaVersion;
        }
        return version;
    }

    pub fn serialize(self: StateSerializationContract, state: []const u8) StateSerializationError!StateSerializationFrame {
        const version = try self.schema_version();
        var frame = self.config.callbacks.serialize(self.config.callbacks.context, state, version, self.config.allocation) catch |err| {
            self.report(failure_for(err));
            return err;
        };
        return self.validate_output(&frame, version, self.config.maximum_serialized_bytes, .serialized_output_too_large);
    }

    pub fn deserialize(self: StateSerializationContract, frame: *const StateSerializationFrame) StateSerializationError!StateSerializationFrame {
        const version = try self.schema_version();
        if (frame.schema_version != version) {
            self.report(.schema_version_mismatch);
            return error.SchemaVersionMismatch;
        }
        return self.deserialize_version(frame, frame.schema_version, version);
    }

    pub fn deserialize_compatible(self: StateSerializationContract, frame: *const StateSerializationFrame) StateSerializationError!StateSerializationFrame {
        const version = try self.schema_version();
        if (frame.schema_version == 0) {
            self.report(.schema_version_mismatch);
            return error.SchemaVersionMismatch;
        }
        return self.deserialize_version(frame, frame.schema_version, version);
    }

    fn deserialize_version(self: StateSerializationContract, frame: *const StateSerializationFrame, source_version: StateSchemaVersion, output_version: StateSchemaVersion) StateSerializationError!StateSerializationFrame {
        var output = self.config.callbacks.deserialize(self.config.callbacks.context, frame.bytes, source_version, self.config.allocation) catch |err| {
            self.report(failure_for(err));
            return err;
        };
        return self.validate_output(&output, output_version, self.config.maximum_deserialized_bytes, .deserialized_output_too_large);
    }

    pub fn verify_deterministic(self: StateSerializationContract, state: []const u8) StateSerializationError!void {
        var first = try self.serialize(state);
        defer first.deinit();
        var second = try self.serialize(state);
        defer second.deinit();
        if (!self.config.callbacks.deterministic(self.config.callbacks.context, first.bytes, second.bytes)) {
            self.report(.non_deterministic);
            return error.NonDeterministic;
        }
    }

    fn validate_output(self: StateSerializationContract, frame: *StateSerializationFrame, version: StateSchemaVersion, maximum_bytes: usize, size_failure: StateSerializationFailure) StateSerializationError!StateSerializationFrame {
        if (!StateSerializationAllocation.eql(frame.allocation, self.config.allocation)) {
            frame.* = undefined;
            self.report(.allocation_mismatch);
            return error.AllocationMismatch;
        }
        if (frame.schema_version != version) {
            frame.deinit();
            self.report(.schema_version_mismatch);
            return error.SchemaVersionMismatch;
        }
        if (frame.bytes.len > maximum_bytes) {
            frame.deinit();
            self.report(size_failure);
            return switch (size_failure) {
                .serialized_output_too_large => error.SerializedOutputTooLarge,
                .deserialized_output_too_large => error.DeserializedOutputTooLarge,
                else => unreachable,
            };
        }
        return frame.*;
    }

    fn report(self: StateSerializationContract, failure: StateSerializationFailure) void {
        self.config.callbacks.failure(self.config.callbacks.context, failure);
    }
};

fn failure_for(err: StateSerializationError) StateSerializationFailure {
    return switch (err) {
        error.InvalidConfiguration => .invalid_configuration,
        error.InvalidSchemaVersion => .invalid_schema_version,
        error.SchemaVersionMismatch => .schema_version_mismatch,
        error.AllocationFailed => .allocation_failed,
        error.SerializationFailed => .serialization_failed,
        error.DeserializationFailed => .deserialization_failed,
        error.SerializedOutputTooLarge => .serialized_output_too_large,
        error.DeserializedOutputTooLarge => .deserialized_output_too_large,
        error.AllocationMismatch => .allocation_mismatch,
        error.NonDeterministic => .non_deterministic,
    };
}

test "serialization callbacks preserve schema ownership allocation and deterministic output" {
    const Fixture = struct {
        var failures: usize = 0;

        fn allocate(_: ?*anyopaque, len: usize) ?[*]u8 {
            const bytes = std.testing.allocator.alloc(u8, len) catch return null;
            return bytes.ptr;
        }
        fn release(_: ?*anyopaque, data: [*]u8, len: usize) void {
            std.testing.allocator.free(data[0..len]);
        }
        fn schema_version(_: ?*anyopaque) StateSchemaVersion {
            return 1;
        }
        fn serialize(_: ?*anyopaque, input: []const u8, version: StateSchemaVersion, allocation: StateSerializationAllocation) StateSerializationError!StateSerializationFrame {
            const bytes = try allocation.allocate(input.len);
            @memcpy(bytes, input);
            return .init(version, bytes, allocation);
        }
        fn deserialize(_: ?*anyopaque, input: []const u8, version: StateSchemaVersion, allocation: StateSerializationAllocation) StateSerializationError!StateSerializationFrame {
            const bytes = try allocation.allocate(input.len);
            @memcpy(bytes, input);
            return .init(version, bytes, allocation);
        }
        fn deterministic(_: ?*anyopaque, first: []const u8, second: []const u8) bool {
            return std.mem.eql(u8, first, second);
        }
        fn failure(_: ?*anyopaque, _: StateSerializationFailure) void {
            failures += 1;
        }
    };
    Fixture.failures = 0;
    const allocation = StateSerializationAllocation{ .context = null, .allocate_fn = Fixture.allocate, .release_fn = Fixture.release };
    const callbacks = StateSerializationCallbacks{ .context = null, .schema_version = Fixture.schema_version, .serialize = Fixture.serialize, .deserialize = Fixture.deserialize, .deterministic = Fixture.deterministic, .failure = Fixture.failure };
    const contract = try StateSerializationContract.init(.{ .maximum_serialized_bytes = 5, .maximum_deserialized_bytes = 5, .allocation = allocation, .callbacks = callbacks });
    var serialized = try contract.serialize("state");
    defer serialized.deinit();
    try std.testing.expectEqual(@as(StateSchemaVersion, 1), serialized.schema_version);
    try std.testing.expectEqualStrings("state", serialized.bytes);
    var restored = try contract.deserialize(&serialized);
    defer restored.deinit();
    try std.testing.expectEqualStrings("state", restored.bytes);
    try contract.verify_deterministic("state");
    try std.testing.expectEqual(@as(usize, 0), Fixture.failures);
}

test "serialization callbacks report schema callback output and determinism failures" {
    const Fixture = struct {
        var failures: usize = 0;
        var bad_schema: bool = false;
        var oversized: bool = false;
        var allocation_fails: bool = false;
        var deserialization_fails: bool = false;
        var sequence: u8 = 0;

        fn allocate(_: ?*anyopaque, len: usize) ?[*]u8 {
            if (allocation_fails) return null;
            const bytes = std.testing.allocator.alloc(u8, len) catch return null;
            return bytes.ptr;
        }
        fn release(_: ?*anyopaque, data: [*]u8, len: usize) void {
            std.testing.allocator.free(data[0..len]);
        }
        fn schema_version(_: ?*anyopaque) StateSchemaVersion {
            return if (bad_schema) 0 else 1;
        }
        fn serialize(_: ?*anyopaque, input: []const u8, version: StateSchemaVersion, allocation: StateSerializationAllocation) StateSerializationError!StateSerializationFrame {
            if (std.mem.eql(u8, input, "fail")) return error.SerializationFailed;
            const extra: usize = if (oversized) 1 else 0;
            const bytes = try allocation.allocate(input.len + extra);
            @memcpy(bytes[0..input.len], input);
            if (oversized) bytes[input.len] = 0;
            if (bytes.len != 0) {
                bytes[0] +%= sequence;
                sequence +%= 1;
            }
            return .init(version, bytes, allocation);
        }
        fn deserialize(_: ?*anyopaque, input: []const u8, version: StateSchemaVersion, allocation: StateSerializationAllocation) StateSerializationError!StateSerializationFrame {
            if (deserialization_fails) return error.DeserializationFailed;
            const bytes = try allocation.allocate(input.len);
            @memcpy(bytes, input);
            return .init(version, bytes, allocation);
        }
        fn deterministic(_: ?*anyopaque, first: []const u8, second: []const u8) bool {
            return std.mem.eql(u8, first, second);
        }
        fn failure(_: ?*anyopaque, _: StateSerializationFailure) void {
            failures += 1;
        }
    };
    Fixture.failures = 0;
    Fixture.bad_schema = false;
    Fixture.oversized = false;
    Fixture.allocation_fails = false;
    Fixture.deserialization_fails = false;
    Fixture.sequence = 0;
    const allocation = StateSerializationAllocation{ .context = null, .allocate_fn = Fixture.allocate, .release_fn = Fixture.release };
    const callbacks = StateSerializationCallbacks{ .context = null, .schema_version = Fixture.schema_version, .serialize = Fixture.serialize, .deserialize = Fixture.deserialize, .deterministic = Fixture.deterministic, .failure = Fixture.failure };
    const contract = try StateSerializationContract.init(.{ .maximum_serialized_bytes = 2, .maximum_deserialized_bytes = 2, .allocation = allocation, .callbacks = callbacks });
    Fixture.allocation_fails = true;
    try std.testing.expectError(error.AllocationFailed, contract.serialize("ok"));
    Fixture.allocation_fails = false;
    try std.testing.expectError(error.SerializationFailed, contract.serialize("fail"));
    Fixture.bad_schema = true;
    try std.testing.expectError(error.InvalidSchemaVersion, contract.serialize("ok"));
    Fixture.bad_schema = false;
    Fixture.oversized = true;
    try std.testing.expectError(error.SerializedOutputTooLarge, contract.serialize("ok"));
    Fixture.oversized = false;
    var frame = try contract.serialize("ok");
    defer frame.deinit();
    Fixture.deserialization_fails = true;
    try std.testing.expectError(error.DeserializationFailed, contract.deserialize(&frame));
    Fixture.deserialization_fails = false;
    Fixture.sequence = 0;
    try std.testing.expectError(error.NonDeterministic, contract.verify_deterministic("ok"));
    try std.testing.expectEqual(@as(usize, 6), Fixture.failures);
}
