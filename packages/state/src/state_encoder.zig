const std = @import("std");
const serialization = @import("serialization_contract.zig");

pub const StateEncodeFailure = enum {
    serialization,
    stream_capacity_exceeded,
    stream_rejected,
};
pub const StateEncodeError = serialization.StateSerializationError || error{ InvalidConfiguration, StreamCapacityExceeded, StreamRejected };
pub const StateEncodeChunk = struct {
    schema_version: serialization.StateSchemaVersion,
    index: usize,
    final: bool,
    bytes: []const u8,
};
pub const StateEncodeStreamFn = *const fn (?*anyopaque, StateEncodeChunk) bool;
pub const StateEncodeStream = struct {
    context: ?*anyopaque,
    write: StateEncodeStreamFn,

    pub fn emit(self: StateEncodeStream, chunk: StateEncodeChunk) bool {
        return self.write(self.context, chunk);
    }
};
pub const StateEncodeFailureFn = *const fn (?*anyopaque, StateEncodeFailure) void;
pub const StateEncoderConfig = struct {
    serialization: serialization.StateSerializationContract,
    maximum_chunk_bytes: usize,
    maximum_chunks: usize,
    failure_context: ?*anyopaque,
    failure: StateEncodeFailureFn,
};
pub const StateEncoder = struct {
    config: StateEncoderConfig,

    pub fn init(config: StateEncoderConfig) StateEncodeError!StateEncoder {
        if (config.maximum_chunk_bytes == 0 or config.maximum_chunks == 0) return error.InvalidConfiguration;
        return .{ .config = config };
    }

    pub fn encode(self: StateEncoder, state: []const u8, stream: StateEncodeStream) StateEncodeError!usize {
        var frame = self.config.serialization.serialize(state) catch |err| {
            self.report(.serialization);
            return err;
        };
        defer frame.deinit();
        const count = chunk_count(frame.bytes.len, self.config.maximum_chunk_bytes);
        if (count > self.config.maximum_chunks) {
            self.report(.stream_capacity_exceeded);
            return error.StreamCapacityExceeded;
        }
        for (0..count) |index| {
            const start = index * self.config.maximum_chunk_bytes;
            const end = @min(start + self.config.maximum_chunk_bytes, frame.bytes.len);
            if (!stream.emit(.{ .schema_version = frame.schema_version, .index = index, .final = index + 1 == count, .bytes = frame.bytes[start..end] })) {
                self.report(.stream_rejected);
                return error.StreamRejected;
            }
        }
        return count;
    }

    fn report(self: StateEncoder, failure: StateEncodeFailure) void {
        self.config.failure(self.config.failure_context, failure);
    }
};

fn chunk_count(length: usize, maximum_chunk_bytes: usize) usize {
    return if (length == 0) 1 else (length - 1) / maximum_chunk_bytes + 1;
}

test "state encoder streams bounded serialized chunks in order" {
    const Fixture = struct {
        var output: [5]u8 = undefined;
        var output_len: usize = 0;
        var chunks: usize = 0;
        var failures: usize = 0;

        fn allocate(_: ?*anyopaque, len: usize) ?[*]u8 {
            const bytes = std.testing.allocator.alloc(u8, len) catch return null;
            return bytes.ptr;
        }
        fn release(_: ?*anyopaque, data: [*]u8, len: usize) void {
            std.testing.allocator.free(data[0..len]);
        }
        fn schema_version(_: ?*anyopaque) serialization.StateSchemaVersion {
            return 1;
        }
        fn serialize(_: ?*anyopaque, input: []const u8, version: serialization.StateSchemaVersion, allocation: serialization.StateSerializationAllocation) serialization.StateSerializationError!serialization.StateSerializationFrame {
            const bytes = try allocation.allocate(input.len);
            @memcpy(bytes, input);
            return .init(version, bytes, allocation);
        }
        fn deserialize(_: ?*anyopaque, input: []const u8, version: serialization.StateSchemaVersion, allocation: serialization.StateSerializationAllocation) serialization.StateSerializationError!serialization.StateSerializationFrame {
            const bytes = try allocation.allocate(input.len);
            @memcpy(bytes, input);
            return .init(version, bytes, allocation);
        }
        fn deterministic(_: ?*anyopaque, first: []const u8, second: []const u8) bool {
            return std.mem.eql(u8, first, second);
        }
        fn serialization_failure(_: ?*anyopaque, _: serialization.StateSerializationFailure) void {}
        fn encode_failure(_: ?*anyopaque, _: StateEncodeFailure) void {
            failures += 1;
        }
        fn stream(_: ?*anyopaque, chunk: StateEncodeChunk) bool {
            if (chunk.index != chunks or chunk.schema_version != 1 or chunk.final != (chunk.index == 2)) return false;
            @memcpy(output[output_len .. output_len + chunk.bytes.len], chunk.bytes);
            output_len += chunk.bytes.len;
            chunks += 1;
            return true;
        }
    };
    Fixture.output_len = 0;
    Fixture.chunks = 0;
    Fixture.failures = 0;
    const allocation = serialization.StateSerializationAllocation{ .context = null, .allocate_fn = Fixture.allocate, .release_fn = Fixture.release };
    const callbacks = serialization.StateSerializationCallbacks{ .context = null, .schema_version = Fixture.schema_version, .serialize = Fixture.serialize, .deserialize = Fixture.deserialize, .deterministic = Fixture.deterministic, .failure = Fixture.serialization_failure };
    const contract = try serialization.StateSerializationContract.init(.{ .maximum_serialized_bytes = 5, .maximum_deserialized_bytes = 5, .allocation = allocation, .callbacks = callbacks });
    const encoder = try StateEncoder.init(.{ .serialization = contract, .maximum_chunk_bytes = 2, .maximum_chunks = 3, .failure_context = null, .failure = Fixture.encode_failure });
    try std.testing.expectEqual(@as(usize, 3), try encoder.encode("state", .{ .context = null, .write = Fixture.stream }));
    try std.testing.expectEqualStrings("state", Fixture.output[0..Fixture.output_len]);
    try std.testing.expectEqual(@as(usize, 0), Fixture.failures);
}

test "state encoder classifies serialization capacity and stream failures" {
    const Fixture = struct {
        var failures: [3]StateEncodeFailure = undefined;
        var failure_count: usize = 0;
        var serialize_fails: bool = false;

        fn allocate(_: ?*anyopaque, len: usize) ?[*]u8 {
            const bytes = std.testing.allocator.alloc(u8, len) catch return null;
            return bytes.ptr;
        }
        fn release(_: ?*anyopaque, data: [*]u8, len: usize) void {
            std.testing.allocator.free(data[0..len]);
        }
        fn schema_version(_: ?*anyopaque) serialization.StateSchemaVersion {
            return 1;
        }
        fn serialize(_: ?*anyopaque, input: []const u8, version: serialization.StateSchemaVersion, allocation: serialization.StateSerializationAllocation) serialization.StateSerializationError!serialization.StateSerializationFrame {
            if (serialize_fails) return error.SerializationFailed;
            const bytes = try allocation.allocate(input.len);
            @memcpy(bytes, input);
            return .init(version, bytes, allocation);
        }
        fn deserialize(_: ?*anyopaque, input: []const u8, version: serialization.StateSchemaVersion, allocation: serialization.StateSerializationAllocation) serialization.StateSerializationError!serialization.StateSerializationFrame {
            const bytes = try allocation.allocate(input.len);
            @memcpy(bytes, input);
            return .init(version, bytes, allocation);
        }
        fn deterministic(_: ?*anyopaque, first: []const u8, second: []const u8) bool {
            return std.mem.eql(u8, first, second);
        }
        fn serialization_failure(_: ?*anyopaque, _: serialization.StateSerializationFailure) void {}
        fn encode_failure(_: ?*anyopaque, failure: StateEncodeFailure) void {
            failures[failure_count] = failure;
            failure_count += 1;
        }
        fn reject(_: ?*anyopaque, _: StateEncodeChunk) bool {
            return false;
        }
    };
    Fixture.failure_count = 0;
    Fixture.serialize_fails = false;
    const allocation = serialization.StateSerializationAllocation{ .context = null, .allocate_fn = Fixture.allocate, .release_fn = Fixture.release };
    const callbacks = serialization.StateSerializationCallbacks{ .context = null, .schema_version = Fixture.schema_version, .serialize = Fixture.serialize, .deserialize = Fixture.deserialize, .deterministic = Fixture.deterministic, .failure = Fixture.serialization_failure };
    const contract = try serialization.StateSerializationContract.init(.{ .maximum_serialized_bytes = 5, .maximum_deserialized_bytes = 5, .allocation = allocation, .callbacks = callbacks });
    const capacity_encoder = try StateEncoder.init(.{ .serialization = contract, .maximum_chunk_bytes = 2, .maximum_chunks = 2, .failure_context = null, .failure = Fixture.encode_failure });
    try std.testing.expectError(error.StreamCapacityExceeded, capacity_encoder.encode("state", .{ .context = null, .write = Fixture.reject }));
    const rejecting_encoder = try StateEncoder.init(.{ .serialization = contract, .maximum_chunk_bytes = 5, .maximum_chunks = 1, .failure_context = null, .failure = Fixture.encode_failure });
    try std.testing.expectError(error.StreamRejected, rejecting_encoder.encode("state", .{ .context = null, .write = Fixture.reject }));
    Fixture.serialize_fails = true;
    try std.testing.expectError(error.SerializationFailed, rejecting_encoder.encode("state", .{ .context = null, .write = Fixture.reject }));
    try std.testing.expectEqualSlices(StateEncodeFailure, &.{ .stream_capacity_exceeded, .stream_rejected, .serialization }, Fixture.failures[0..Fixture.failure_count]);
    try std.testing.expectError(error.InvalidConfiguration, StateEncoder.init(.{ .serialization = contract, .maximum_chunk_bytes = 0, .maximum_chunks = 1, .failure_context = null, .failure = Fixture.encode_failure }));
}
