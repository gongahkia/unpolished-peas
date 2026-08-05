const std = @import("std");
const core = @import("minna-san-core");
const format = @import("capture_format.zig");
const recorder = @import("capture_recorder.zig");
const event = @import("event.zig");
const poll_runtime = @import("poll_runtime.zig");

pub const CaptureReplayDivergenceKind = enum {
    record_order,
    apply_rejected,
};

pub const CaptureReplayDivergence = struct {
    kind: CaptureReplayDivergenceKind,
    sequence: u64,
};

pub const CaptureReplayApplyFn = *const fn (?*anyopaque, format.CaptureRecord) bool;
pub const CaptureReplayDivergenceFn = *const fn (?*anyopaque, CaptureReplayDivergence) void;

pub const CaptureReplayConfig = struct {
    manual_clock: *core.ManualClock,
    poll_runtime: *poll_runtime.PollRuntime,
    streams: []const recorder.CaptureStream,
    context: ?*anyopaque = null,
    apply: ?CaptureReplayApplyFn = null,
    on_divergence: ?CaptureReplayDivergenceFn = null,
};

pub const CaptureReplayError = format.CaptureFormatError || poll_runtime.PollRuntimeError || core.ClockError || error{
    InvalidConfiguration,
    ReplayDivergence,
    TimeRegression,
    MalformedEvent,
};

pub const CaptureReplayStep = struct {
    record: format.CaptureRecord,
    event: ?event.EventEnvelope = null,

    pub fn deinit(self: *CaptureReplayStep) void {
        if (self.event) |*value| value.deinit();
        self.* = undefined;
    }
};

pub const CaptureReplay = struct {
    config: CaptureReplayConfig,
    stream_index: usize = 0,
    stream_offset: usize = format.capture_stream_header_bytes,
    next_record_sequence: u64 = 0,
    next_event_sequence: u64 = 0,
    replayed_records: u64 = 0,

    pub fn init(config: CaptureReplayConfig) CaptureReplayError!CaptureReplay {
        if (config.streams.len == 0 or config.streams.len > recorder.max_capture_streams) return error.InvalidConfiguration;
        for (config.streams, 0..) |stream, index| {
            if (stream.sequence != index) return error.InvalidConfiguration;
            _ = try format.decode_capture_stream_header(stream.bytes);
        }
        return .{ .config = config };
    }

    pub fn poll(self: *CaptureReplay) CaptureReplayError!?CaptureReplayStep {
        const record_value = (try self.next_record()) orelse return null;
        if (record_value.sequence != self.next_record_sequence) {
            self.notify_divergence(.record_order, record_value.sequence);
            return error.ReplayDivergence;
        }
        if (record_value.timestamp_ns < self.config.manual_clock.now_ns) return error.TimeRegression;
        try self.config.manual_clock.advance(record_value.timestamp_ns - self.config.manual_clock.now_ns);
        if (self.config.apply) |apply| {
            if (!apply(self.config.context, record_value)) {
                self.notify_divergence(.apply_rejected, record_value.sequence);
                return error.ReplayDivergence;
            }
        }
        self.next_record_sequence +%= 1;
        self.replayed_records +%= 1;
        var step = CaptureReplayStep{ .record = record_value };
        if (record_value.kind == .event) {
            var replay_event = try self.decode_event(record_value);
            self.config.poll_runtime.enqueue(replay_event) catch |err| {
                replay_event.deinit();
                return err;
            };
            var outcome = try self.config.poll_runtime.poll(.{ .now_ns = self.config.manual_clock.now_ns });
            step.event = outcome.event orelse return error.MalformedEvent;
            outcome.event = null;
        }
        return step;
    }

    pub fn record_count(self: *const CaptureReplay) u64 {
        return self.replayed_records;
    }

    fn next_record(self: *CaptureReplay) CaptureReplayError!?format.CaptureRecord {
        while (self.stream_index < self.config.streams.len) {
            const stream = self.config.streams[self.stream_index];
            if (self.stream_offset == stream.bytes.len) {
                self.stream_index += 1;
                self.stream_offset = format.capture_stream_header_bytes;
                continue;
            }
            if (self.stream_offset > stream.bytes.len or stream.bytes.len - self.stream_offset < format.capture_record_header_bytes) return error.MalformedCapture;
            const header = stream.bytes[self.stream_offset..];
            const payload_len: usize = std.mem.readInt(u32, header[20..24], .big);
            const encoded_len = std.math.add(usize, format.capture_record_header_bytes, payload_len) catch return error.MalformedCapture;
            const end = std.math.add(usize, self.stream_offset, encoded_len) catch return error.MalformedCapture;
            if (end > stream.bytes.len) return error.MalformedCapture;
            self.stream_offset = end;
            return try format.decode_capture_record(stream.bytes[end - encoded_len .. end]);
        }
        return null;
    }

    fn decode_event(self: *CaptureReplay, record_value: format.CaptureRecord) CaptureReplayError!event.EventEnvelope {
        if (record_value.payload.len == 0) return error.MalformedEvent;
        const replayed_event: event.Event = switch (record_value.payload[0]) {
            1 => if (record_value.payload.len == 1) .{ .connected = {} } else return error.MalformedEvent,
            2 => if (record_value.payload.len == 1) .{ .disconnected = {} } else return error.MalformedEvent,
            3 => .{ .message = .{ .buffer = .{ .borrowed = .init(record_value.payload[1..]) } } },
            4 => if (record_value.payload.len == 9) .{ .overflow = .{ .dropped_count = std.mem.readInt(u64, record_value.payload[1..9], .big) } } else return error.MalformedEvent,
            else => return error.MalformedEvent,
        };
        const envelope = event.EventEnvelope{ .sequence = self.next_event_sequence, .mode = .replay, .event = replayed_event };
        self.next_event_sequence +%= 1;
        return envelope;
    }

    fn notify_divergence(self: *CaptureReplay, kind: CaptureReplayDivergenceKind, sequence: u64) void {
        const callback = self.config.on_divergence orelse return;
        callback(self.config.context, .{ .kind = kind, .sequence = sequence });
    }
};

test "capture replay advances virtual time and injects captured events through polling" {
    const Apply = struct {
        var applied: usize = 0;

        fn run(_: ?*anyopaque, _: format.CaptureRecord) bool {
            applied += 1;
            return true;
        }
    };
    var stream: [format.capture_stream_header_bytes + format.capture_record_header_bytes + format.capture_record_header_bytes + 1]u8 = undefined;
    _ = try format.encode_capture_stream_header(.{}, stream[0..format.capture_stream_header_bytes]);
    const clock_record = try format.encode_capture_record(.{ .kind = .clock, .sequence = 0, .timestamp_ns = 5, .payload = "" }, stream[format.capture_stream_header_bytes..]);
    const event_start = format.capture_stream_header_bytes + clock_record.len;
    _ = try format.encode_capture_record(.{ .kind = .event, .sequence = 1, .timestamp_ns = 7, .payload = &.{1} }, stream[event_start..]);
    var manual = core.ManualClock.init(0);
    const sdk = try @import("sdk_config.zig").SdkConfigBuilder.init().with_clock(manual.clock()).build();
    var polling = poll_runtime.PollRuntime.init(std.testing.allocator, sdk);
    defer polling.deinit();
    Apply.applied = 0;
    var replay = try CaptureReplay.init(.{ .manual_clock = &manual, .poll_runtime = &polling, .streams = &.{.{ .sequence = 0, .bytes = stream[0..] }}, .apply = Apply.run });
    var first = (try replay.poll()).?;
    defer first.deinit();
    try std.testing.expect(first.event == null);
    try std.testing.expectEqual(@as(core.TimeNs, 5), manual.now_ns);
    var second = (try replay.poll()).?;
    defer second.deinit();
    try std.testing.expectEqual(event.EventMode.replay, second.event.?.mode);
    try std.testing.expect(second.event.?.event == .connected);
    try std.testing.expectEqual(@as(core.TimeNs, 7), manual.now_ns);
    try std.testing.expect((try replay.poll()) == null);
    try std.testing.expectEqual(@as(usize, 2), Apply.applied);
    try std.testing.expectEqual(@as(u64, 2), replay.record_count());
}

test "capture replay detects record-order and consumer divergences" {
    const Divergence = struct {
        var value: ?CaptureReplayDivergence = null;

        fn reject(_: ?*anyopaque, _: format.CaptureRecord) bool {
            return false;
        }

        fn receive(_: ?*anyopaque, divergence: CaptureReplayDivergence) void {
            @This().value = divergence;
        }
    };
    var stream: [format.capture_stream_header_bytes + format.capture_record_header_bytes]u8 = undefined;
    _ = try format.encode_capture_stream_header(.{}, stream[0..format.capture_stream_header_bytes]);
    _ = try format.encode_capture_record(.{ .kind = .route, .sequence = 1, .timestamp_ns = 0, .payload = "" }, stream[format.capture_stream_header_bytes..]);
    var manual = core.ManualClock.init(0);
    const sdk = try @import("sdk_config.zig").SdkConfigBuilder.init().with_clock(manual.clock()).build();
    var polling = poll_runtime.PollRuntime.init(std.testing.allocator, sdk);
    defer polling.deinit();
    Divergence.value = null;
    var replay = try CaptureReplay.init(.{ .manual_clock = &manual, .poll_runtime = &polling, .streams = &.{.{ .sequence = 0, .bytes = stream[0..] }}, .on_divergence = Divergence.receive });
    try std.testing.expectError(error.ReplayDivergence, replay.poll());
    try std.testing.expectEqual(CaptureReplayDivergence{ .kind = .record_order, .sequence = 1 }, Divergence.value.?);
    _ = try format.encode_capture_record(.{ .kind = .route, .sequence = 0, .timestamp_ns = 0, .payload = "" }, stream[format.capture_stream_header_bytes..]);
    Divergence.value = null;
    replay = try CaptureReplay.init(.{ .manual_clock = &manual, .poll_runtime = &polling, .streams = &.{.{ .sequence = 0, .bytes = stream[0..] }}, .apply = Divergence.reject, .on_divergence = Divergence.receive });
    try std.testing.expectError(error.ReplayDivergence, replay.poll());
    try std.testing.expectEqual(CaptureReplayDivergence{ .kind = .apply_rejected, .sequence = 0 }, Divergence.value.?);
}
