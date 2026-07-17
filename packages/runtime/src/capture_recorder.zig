const std = @import("std");
const format = @import("capture_format.zig");

pub const max_capture_streams: usize = 16;

pub const CaptureRecorderFailureKind = enum {
    disabled,
    record_too_large,
    backpressured,
    allocation_failed,
};

pub const CaptureRecorderFailure = struct {
    kind: CaptureRecorderFailureKind,
    sequence: ?u64,
};

pub const CaptureRecorderFailureFn = *const fn (?*anyopaque, CaptureRecorderFailure) void;

pub const CaptureRecorderConfig = struct {
    enabled: bool = false,
    maximum_stream_bytes: usize,
    maximum_streams: usize = 1,
    failure_context: ?*anyopaque = null,
    on_failure: ?CaptureRecorderFailureFn = null,
};

pub const CaptureRecorderError = std.mem.Allocator.Error || format.CaptureFormatError || error{
    InvalidConfiguration,
    CaptureDisabled,
    CaptureBackpressured,
    StreamOutputTooSmall,
};

pub const CaptureStream = struct {
    sequence: u64,
    bytes: []const u8,
};

const StoredCaptureStream = struct {
    sequence: u64,
    bytes: std.ArrayListUnmanaged(u8),
};

pub const CaptureRecorder = struct {
    allocator: std.mem.Allocator,
    config: CaptureRecorderConfig,
    enabled: bool,
    current_sequence: u64 = 0,
    current: std.ArrayListUnmanaged(u8) = .empty,
    completed: std.ArrayListUnmanaged(StoredCaptureStream) = .empty,
    records: u64 = 0,
    rotations: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, config: CaptureRecorderConfig) CaptureRecorderError!CaptureRecorder {
        if (config.maximum_stream_bytes < format.capture_stream_header_bytes + format.capture_record_header_bytes or config.maximum_streams == 0 or config.maximum_streams > max_capture_streams) return error.InvalidConfiguration;
        var recorder = CaptureRecorder{ .allocator = allocator, .config = config, .enabled = config.enabled };
        if (recorder.enabled) recorder.current = try recorder.new_stream();
        return recorder;
    }

    pub fn deinit(self: *CaptureRecorder) void {
        self.current.deinit(self.allocator);
        for (self.completed.items) |*stream| stream.bytes.deinit(self.allocator);
        self.completed.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn record(self: *CaptureRecorder, record_value: format.CaptureRecord) CaptureRecorderError!void {
        if (!self.enabled) {
            self.notify_failure(.disabled, record_value.sequence);
            return error.CaptureDisabled;
        }
        const encoded_len = std.math.add(usize, format.capture_record_header_bytes, record_value.payload.len) catch {
            self.notify_failure(.record_too_large, record_value.sequence);
            return error.PayloadTooLarge;
        };
        if (record_value.payload.len > format.max_capture_record_payload_bytes or encoded_len > self.config.maximum_stream_bytes - format.capture_stream_header_bytes) {
            self.notify_failure(.record_too_large, record_value.sequence);
            return error.PayloadTooLarge;
        }
        const appended_len = std.math.add(usize, self.current.items.len, encoded_len) catch {
            self.notify_failure(.record_too_large, record_value.sequence);
            return error.PayloadTooLarge;
        };
        if (appended_len > self.config.maximum_stream_bytes) self.rotate(record_value.sequence, encoded_len) catch |err| return err;
        self.current.ensureUnusedCapacity(self.allocator, encoded_len) catch {
            self.notify_failure(.allocation_failed, record_value.sequence);
            return error.OutOfMemory;
        };
        const start = self.current.items.len;
        self.current.items.len += encoded_len;
        _ = format.encode_capture_record(record_value, self.current.items[start..]) catch |err| {
            self.current.items.len = start;
            if (err == error.PayloadTooLarge) self.notify_failure(.record_too_large, record_value.sequence);
            return err;
        };
        self.records +%= 1;
    }

    pub fn stream_count(self: *const CaptureRecorder) usize {
        return self.completed.items.len + @intFromBool(self.enabled);
    }

    pub fn record_count(self: *const CaptureRecorder) u64 {
        return self.records;
    }

    pub fn rotation_count(self: *const CaptureRecorder) u64 {
        return self.rotations;
    }

    pub fn list_streams(self: *const CaptureRecorder, output: []CaptureStream) CaptureRecorderError!usize {
        const count = self.stream_count();
        if (output.len < count) return error.StreamOutputTooSmall;
        for (self.completed.items, 0..) |stream, index| output[index] = .{ .sequence = stream.sequence, .bytes = stream.bytes.items };
        if (self.enabled) output[self.completed.items.len] = .{ .sequence = self.current_sequence, .bytes = self.current.items };
        return count;
    }

    fn rotate(self: *CaptureRecorder, record_sequence: u64, pending_bytes: usize) CaptureRecorderError!void {
        if (self.completed.items.len + 1 >= self.config.maximum_streams) {
            self.notify_failure(.backpressured, record_sequence);
            return error.CaptureBackpressured;
        }
        self.completed.ensureUnusedCapacity(self.allocator, 1) catch {
            self.notify_failure(.allocation_failed, record_sequence);
            return error.OutOfMemory;
        };
        var next = self.new_stream() catch {
            self.notify_failure(.allocation_failed, record_sequence);
            return error.OutOfMemory;
        };
        next.ensureUnusedCapacity(self.allocator, pending_bytes) catch {
            next.deinit(self.allocator);
            self.notify_failure(.allocation_failed, record_sequence);
            return error.OutOfMemory;
        };
        const previous = self.current;
        self.current = next;
        self.completed.appendAssumeCapacity(.{ .sequence = self.current_sequence, .bytes = previous });
        self.current_sequence +%= 1;
        self.rotations +%= 1;
    }

    fn new_stream(self: *CaptureRecorder) std.mem.Allocator.Error!std.ArrayListUnmanaged(u8) {
        var stream: std.ArrayListUnmanaged(u8) = .empty;
        errdefer stream.deinit(self.allocator);
        try stream.ensureUnusedCapacity(self.allocator, format.capture_stream_header_bytes);
        stream.items.len = format.capture_stream_header_bytes;
        _ = format.encode_capture_stream_header(.{}, stream.items) catch unreachable;
        return stream;
    }

    fn notify_failure(self: *CaptureRecorder, kind: CaptureRecorderFailureKind, sequence: ?u64) void {
        const callback = self.config.on_failure orelse return;
        callback(self.config.failure_context, .{ .kind = kind, .sequence = sequence });
    }
};

test "capture recorders remain disabled until explicitly enabled" {
    const FailureCapture = struct {
        var failure: ?CaptureRecorderFailure = null;

        fn receive(_: ?*anyopaque, value: CaptureRecorderFailure) void {
            failure = value;
        }
    };
    FailureCapture.failure = null;
    var recorder = try CaptureRecorder.init(std.testing.allocator, .{ .maximum_stream_bytes = format.capture_stream_header_bytes + format.capture_record_header_bytes, .on_failure = FailureCapture.receive });
    defer recorder.deinit();
    try std.testing.expectError(error.CaptureDisabled, recorder.record(.{ .kind = .event, .sequence = 7, .timestamp_ns = 0, .payload = "" }));
    try std.testing.expectEqual(CaptureRecorderFailure{ .kind = .disabled, .sequence = 7 }, FailureCapture.failure.?);
    try std.testing.expectEqual(@as(usize, 0), recorder.stream_count());
}

test "capture recorders rotate bounded streams and report backpressure" {
    const FailureCapture = struct {
        var failure: ?CaptureRecorderFailure = null;

        fn receive(_: ?*anyopaque, value: CaptureRecorderFailure) void {
            failure = value;
        }
    };
    const stream_bytes = format.capture_stream_header_bytes + format.capture_record_header_bytes + 1;
    FailureCapture.failure = null;
    var recorder = try CaptureRecorder.init(std.testing.allocator, .{ .enabled = true, .maximum_stream_bytes = stream_bytes, .maximum_streams = 2, .on_failure = FailureCapture.receive });
    defer recorder.deinit();
    try recorder.record(.{ .kind = .packet, .sequence = 0, .timestamp_ns = 1, .payload = "a" });
    try recorder.record(.{ .kind = .route, .sequence = 1, .timestamp_ns = 2, .payload = "b" });
    try std.testing.expectEqual(@as(u64, 2), recorder.record_count());
    try std.testing.expectEqual(@as(u64, 1), recorder.rotation_count());
    var streams: [2]CaptureStream = undefined;
    try std.testing.expectEqual(@as(usize, 2), try recorder.list_streams(streams[0..]));
    try std.testing.expectEqual(@as(u64, 0), streams[0].sequence);
    try std.testing.expectEqual(@as(u64, 1), streams[1].sequence);
    try std.testing.expectEqual(format.CaptureRecordKind.packet, (try format.decode_capture_record(streams[0].bytes[format.capture_stream_header_bytes..])).kind);
    try std.testing.expectEqual(format.CaptureRecordKind.route, (try format.decode_capture_record(streams[1].bytes[format.capture_stream_header_bytes..])).kind);
    try std.testing.expectError(error.CaptureBackpressured, recorder.record(.{ .kind = .clock, .sequence = 2, .timestamp_ns = 3, .payload = "c" }));
    try std.testing.expectEqual(CaptureRecorderFailure{ .kind = .backpressured, .sequence = 2 }, FailureCapture.failure.?);
}

test "capture recorders reject invalid capacities and oversize records" {
    try std.testing.expectError(error.InvalidConfiguration, CaptureRecorder.init(std.testing.allocator, .{ .maximum_stream_bytes = format.capture_stream_header_bytes + format.capture_record_header_bytes - 1 }));
    try std.testing.expectError(error.InvalidConfiguration, CaptureRecorder.init(std.testing.allocator, .{ .maximum_stream_bytes = format.capture_stream_header_bytes + format.capture_record_header_bytes, .maximum_streams = 0 }));
    var recorder = try CaptureRecorder.init(std.testing.allocator, .{ .enabled = true, .maximum_stream_bytes = format.capture_stream_header_bytes + format.capture_record_header_bytes, .on_failure = null });
    defer recorder.deinit();
    try std.testing.expectError(error.PayloadTooLarge, recorder.record(.{ .kind = .configuration, .sequence = 0, .timestamp_ns = 0, .payload = "x" }));
    var output: [0]CaptureStream = .{};
    try std.testing.expectError(error.StreamOutputTooSmall, recorder.list_streams(output[0..]));
}
