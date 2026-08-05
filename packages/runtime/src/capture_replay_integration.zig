const std = @import("std");
const core = @import("minna-san-core");
const protocol = @import("minna-san-protocol");
const topology = @import("minna-san-topology");
const transport = @import("minna-san-transport");
const state = @import("minna-san-state");
const format = @import("capture_format.zig");
const recorder = @import("capture_recorder.zig");
const redaction = @import("capture_redaction.zig");
const replay = @import("capture_replay.zig");
const poll_runtime = @import("poll_runtime.zig");

const StateCallbacks = struct {
    var corrected: ?state.StatePredictionSequence = null;
    var replayed: ?state.StatePredictionSequence = null;

    fn simulate(_: ?*anyopaque, _: state.StatePredictionInput) bool {
        return true;
    }

    fn correct(_: ?*anyopaque, authoritative: core.BorrowedBuffer) bool {
        return std.mem.eql(u8, authoritative.bytes, "ok");
    }

    fn replay_input(_: ?*anyopaque, _: state.StatePredictionInput) bool {
        return true;
    }

    fn event(_: ?*anyopaque, value: state.StateReconciliationEvent) void {
        switch (value) {
            .corrected => |sequence| corrected = sequence,
            .replayed => |sequence| replayed = sequence,
            .divergence => unreachable,
        }
    }
};

const SuccessFixture = struct {
    route: *topology.RouteTransition,
    connection: *transport.TransportConnectionTracker,
    reconciliation: *state.StateReconciliation,
    redacted_packet: bool = false,

    fn apply(context: ?*anyopaque, record_value: format.CaptureRecord) bool {
        const self: *SuccessFixture = @ptrCast(@alignCast(context orelse return false));
        switch (record_value.kind) {
            .route => {
                if (!std.mem.eql(u8, record_value.payload, &.{1})) return false;
                self.route.begin(.relay, 1) catch return false;
                self.route.commit(1) catch return false;
                self.connection.transition(.connecting) catch return false;
            },
            .packet => {
                const decoded = protocol.decode_packet(record_value.payload) catch return false;
                self.redacted_packet = record_value.flags.redacted and std.mem.eql(u8, decoded.payload, &[_]u8{ 0, 0, 0, 0, 0, 0 });
                self.connection.transition(.connected) catch return false;
            },
            .configuration => self.reconciliation.reconcile(0, .init(record_value.payload)) catch return false,
            .event => {},
            else => return false,
        }
        return true;
    }
};

const Divergence = struct {
    var value: ?replay.CaptureReplayDivergence = null;

    fn receive(_: ?*anyopaque, divergence: replay.CaptureReplayDivergence) void {
        value = divergence;
    }
};

test "capture replay reproduces redacted route transport protocol and state outcomes" {
    const secret = "secret";
    const packet_bytes = protocol.packet_header_bytes + secret.len;
    var packet: [packet_bytes]u8 = undefined;
    _ = try protocol.encode_packet(.{ .version = protocol.v1_version, .extension_id = 0, .payload = secret }, packet[0..]);
    var capture = try recorder.CaptureRecorder.init(std.testing.allocator, .{ .enabled = true, .maximum_stream_bytes = 160 });
    defer capture.deinit();
    try capture.record(.{ .kind = .route, .sequence = 0, .timestamp_ns = 3, .payload = &.{1} });
    const secret_field = [_]redaction.CaptureRedactionField{.{ .class = .credential, .offset = protocol.packet_header_bytes, .len = secret.len }};
    var redaction_scratch: [packet_bytes]u8 = undefined;
    try capture.record_redacted(redaction.CaptureRedactor.init(.{}), .{ .kind = .packet, .sequence = 1, .timestamp_ns = 5, .payload = packet[0..] }, secret_field[0..], redaction_scratch[0..]);
    try capture.record(.{ .kind = .configuration, .sequence = 2, .timestamp_ns = 7, .payload = "ok" });
    try capture.record(.{ .kind = .event, .sequence = 3, .timestamp_ns = 9, .payload = &.{1} });
    var streams: [1]recorder.CaptureStream = undefined;
    try std.testing.expectEqual(@as(usize, 1), try capture.list_streams(streams[0..]));
    try std.testing.expect(std.mem.indexOf(u8, streams[0].bytes, secret) == null);

    var route = try topology.RouteTransition.init(.{ .initial_route = .direct, .initial_security_epoch = 1, .maximum_diagnostics = 2 });
    var connection = transport.TransportConnectionTracker{};
    var prediction = try state.StateClientPrediction.init(std.testing.allocator, .{ .maximum_history = 2, .maximum_input_bytes = 1, .simulation_context = null, .simulate = StateCallbacks.simulate });
    defer prediction.deinit();
    _ = try prediction.submit("a");
    _ = try prediction.submit("b");
    var reconciliation = try state.StateReconciliation.init(.{ .prediction = &prediction, .maximum_replay = 2, .context = null, .correct = StateCallbacks.correct, .replay = StateCallbacks.replay_input, .event = StateCallbacks.event });
    var fixture = SuccessFixture{ .route = &route, .connection = &connection, .reconciliation = &reconciliation };
    StateCallbacks.corrected = null;
    StateCallbacks.replayed = null;
    var manual = core.ManualClock.init(0);
    const sdk = try @import("sdk_config.zig").SdkConfigBuilder.init().with_clock(manual.clock()).build();
    var polling = poll_runtime.PollRuntime.init(std.testing.allocator, sdk);
    defer polling.deinit();
    var capture_replay = try replay.CaptureReplay.init(.{ .manual_clock = &manual, .poll_runtime = &polling, .streams = streams[0..], .context = &fixture, .apply = SuccessFixture.apply });
    var replay_events: usize = 0;
    while (try capture_replay.poll()) |next| {
        var step = next;
        defer step.deinit();
        if (step.event != null) replay_events += 1;
    }
    try std.testing.expectEqual(topology.RouteTransitionRoute.relay, route.route());
    try std.testing.expectEqual(transport.TransportConnectionState.connected, connection.state);
    try std.testing.expect(fixture.redacted_packet);
    try std.testing.expectEqual(@as(state.StatePredictionSequence, 0), StateCallbacks.corrected.?);
    try std.testing.expectEqual(@as(state.StatePredictionSequence, 1), StateCallbacks.replayed.?);
    try std.testing.expectEqual(@as(usize, 1), replay_events);
    try std.testing.expectEqual(@as(core.TimeNs, 9), manual.now_ns);
    try std.testing.expectEqual(@as(u64, 4), capture_replay.record_count());
}

test "capture replay exposes protocol and state failures as deterministic divergences" {
    const FailureFixture = struct {
        const Kind = enum { protocol, state };

        reconciliation: *state.StateReconciliation,
        kind: ?Kind = null,

        fn apply(context: ?*anyopaque, record_value: format.CaptureRecord) bool {
            const self: *@This() = @ptrCast(@alignCast(context orelse return false));
            switch (record_value.kind) {
                .packet => {
                    _ = protocol.decode_packet(record_value.payload) catch {
                        self.kind = .protocol;
                        return false;
                    };
                },
                .configuration => self.reconciliation.reconcile(0, .init(record_value.payload)) catch {
                    self.kind = .state;
                    return false;
                },
                else => return false,
            }
            return true;
        }
    };
    var prediction = try state.StateClientPrediction.init(std.testing.allocator, .{ .maximum_history = 1, .maximum_input_bytes = 1, .simulation_context = null, .simulate = StateCallbacks.simulate });
    defer prediction.deinit();
    _ = try prediction.submit("a");
    var reconciliation = try state.StateReconciliation.init(.{ .prediction = &prediction, .maximum_replay = 1, .context = null, .correct = StateCallbacks.correct, .replay = StateCallbacks.replay_input, .event = StateCallbacks.event });
    var fixture = FailureFixture{ .reconciliation = &reconciliation };
    var stream: [format.capture_stream_header_bytes + format.capture_record_header_bytes + 3]u8 = undefined;
    _ = try format.encode_capture_stream_header(.{}, stream[0..format.capture_stream_header_bytes]);
    _ = try format.encode_capture_record(.{ .kind = .packet, .sequence = 0, .timestamp_ns = 4, .payload = &.{ 0, 0, 0 } }, stream[format.capture_stream_header_bytes..]);
    var manual = core.ManualClock.init(0);
    const sdk = try @import("sdk_config.zig").SdkConfigBuilder.init().with_clock(manual.clock()).build();
    var polling = poll_runtime.PollRuntime.init(std.testing.allocator, sdk);
    defer polling.deinit();
    Divergence.value = null;
    var capture_replay = try replay.CaptureReplay.init(.{ .manual_clock = &manual, .poll_runtime = &polling, .streams = &.{.{ .sequence = 0, .bytes = stream[0..] }}, .context = &fixture, .apply = FailureFixture.apply, .on_divergence = Divergence.receive });
    try std.testing.expectError(error.ReplayDivergence, capture_replay.poll());
    try std.testing.expectEqual(FailureFixture.Kind.protocol, fixture.kind.?);
    try std.testing.expectEqual(replay.CaptureReplayDivergence{ .kind = .apply_rejected, .sequence = 0 }, Divergence.value.?);
    try std.testing.expectEqual(@as(core.TimeNs, 4), manual.now_ns);

    _ = try format.encode_capture_record(.{ .kind = .configuration, .sequence = 0, .timestamp_ns = 6, .payload = "bad" }, stream[format.capture_stream_header_bytes..]);
    fixture.kind = null;
    Divergence.value = null;
    manual = core.ManualClock.init(0);
    capture_replay = try replay.CaptureReplay.init(.{ .manual_clock = &manual, .poll_runtime = &polling, .streams = &.{.{ .sequence = 0, .bytes = stream[0..] }}, .context = &fixture, .apply = FailureFixture.apply, .on_divergence = Divergence.receive });
    try std.testing.expectError(error.ReplayDivergence, capture_replay.poll());
    try std.testing.expectEqual(FailureFixture.Kind.state, fixture.kind.?);
    try std.testing.expectEqual(replay.CaptureReplayDivergence{ .kind = .apply_rejected, .sequence = 0 }, Divergence.value.?);
    try std.testing.expectEqual(@as(core.TimeNs, 6), manual.now_ns);
}
