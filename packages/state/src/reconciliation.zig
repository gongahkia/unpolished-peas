const core = @import("minna-san-core");
const prediction = @import("client_prediction.zig");

pub const StateReconciliationEvent = union(enum) {
    corrected: prediction.StatePredictionSequence,
    replayed: prediction.StatePredictionSequence,
    divergence: prediction.StatePredictionSequence,
};
pub const StateReconciliationCorrectionFn = *const fn (?*anyopaque, core.BorrowedBuffer) bool;
pub const StateReconciliationReplayFn = *const fn (?*anyopaque, prediction.StatePredictionInput) bool;
pub const StateReconciliationEventFn = *const fn (?*anyopaque, StateReconciliationEvent) void;
pub const StateReconciliationError = error{ InvalidConfiguration, CorrectionRejected, ReplayCapacityExceeded };
pub const StateReconciliationConfig = struct {
    prediction: *prediction.StateClientPrediction,
    maximum_replay: usize,
    context: ?*anyopaque,
    correct: StateReconciliationCorrectionFn,
    replay: StateReconciliationReplayFn,
    event: StateReconciliationEventFn,
};
pub const StateReconciliation = struct {
    config: StateReconciliationConfig,

    pub fn init(config: StateReconciliationConfig) StateReconciliationError!StateReconciliation {
        if (config.maximum_replay == 0 or config.maximum_replay > 64) return error.InvalidConfiguration;
        return .{ .config = config };
    }
    pub fn reconcile(self: StateReconciliation, acknowledged_sequence: prediction.StatePredictionSequence, authoritative: core.BorrowedBuffer) StateReconciliationError!void {
        if (!self.config.correct(self.config.context, authoritative)) return error.CorrectionRejected;
        self.config.prediction.acknowledge_through(acknowledged_sequence);
        if (self.config.prediction.history.items.len > self.config.maximum_replay) return error.ReplayCapacityExceeded;
        var pending: [64]prediction.StatePredictionInput = undefined;
        const count = self.config.prediction.pending(pending[0..self.config.maximum_replay]);
        self.config.event(self.config.context, .{ .corrected = acknowledged_sequence });
        for (pending[0..count]) |input| {
            if (self.config.replay(self.config.context, input)) self.config.event(self.config.context, .{ .replayed = input.sequence }) else self.config.event(self.config.context, .{ .divergence = input.sequence });
        }
    }
};

test "reconciliation applies authority and replays bounded prediction history" {
    const Fixture = struct {
        var events: [3]StateReconciliationEvent = undefined;
        var count: usize = 0;
        fn simulate(_: ?*anyopaque, _: prediction.StatePredictionInput) bool {
            return true;
        }
        fn correct(_: ?*anyopaque, state: core.BorrowedBuffer) bool {
            return @import("std").mem.eql(u8, state.bytes, "ok");
        }
        fn replay(_: ?*anyopaque, _: prediction.StatePredictionInput) bool {
            return true;
        }
        fn event(_: ?*anyopaque, value: StateReconciliationEvent) void {
            events[count] = value;
            count += 1;
        }
    };
    var client = try prediction.StateClientPrediction.init(@import("std").testing.allocator, .{ .maximum_history = 2, .maximum_input_bytes = 1, .simulation_context = null, .simulate = Fixture.simulate });
    defer client.deinit();
    _ = try client.submit("a");
    _ = try client.submit("b");
    Fixture.count = 0;
    const reconciliation = try StateReconciliation.init(.{ .prediction = &client, .maximum_replay = 2, .context = null, .correct = Fixture.correct, .replay = Fixture.replay, .event = Fixture.event });
    try reconciliation.reconcile(0, .init("ok"));
    try @import("std").testing.expectEqual(StateReconciliationEvent{ .corrected = 0 }, Fixture.events[0]);
    try @import("std").testing.expectEqual(StateReconciliationEvent{ .replayed = 1 }, Fixture.events[1]);
}

test "reconciliation reports rejected corrections and replay divergence" {
    const Fixture = struct {
        var event_value: ?StateReconciliationEvent = null;
        fn simulate(_: ?*anyopaque, _: prediction.StatePredictionInput) bool {
            return true;
        }
        fn reject(_: ?*anyopaque, _: core.BorrowedBuffer) bool {
            return false;
        }
        fn correct(_: ?*anyopaque, _: core.BorrowedBuffer) bool {
            return true;
        }
        fn replay(_: ?*anyopaque, _: prediction.StatePredictionInput) bool {
            return false;
        }
        fn event(_: ?*anyopaque, value: StateReconciliationEvent) void {
            event_value = value;
        }
    };
    var client = try prediction.StateClientPrediction.init(@import("std").testing.allocator, .{ .maximum_history = 2, .maximum_input_bytes = 1, .simulation_context = null, .simulate = Fixture.simulate });
    defer client.deinit();
    _ = try client.submit("a");
    const rejected = try StateReconciliation.init(.{ .prediction = &client, .maximum_replay = 2, .context = null, .correct = Fixture.reject, .replay = Fixture.replay, .event = Fixture.event });
    try @import("std").testing.expectError(error.CorrectionRejected, rejected.reconcile(0, .init("bad")));
    _ = try client.submit("a");
    Fixture.event_value = null;
    const divergence = try StateReconciliation.init(.{ .prediction = &client, .maximum_replay = 2, .context = null, .correct = Fixture.correct, .replay = Fixture.replay, .event = Fixture.event });
    try divergence.reconcile(0, .init("ok"));
    try @import("std").testing.expectEqual(StateReconciliationEvent{ .divergence = 1 }, Fixture.event_value.?);
}
