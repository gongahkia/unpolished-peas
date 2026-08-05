const std = @import("std");
const core = @import("minna-san-core");

pub const StatePredictionSequence = u64;
pub const StatePredictionInput = struct { sequence: StatePredictionSequence, payload: core.BorrowedBuffer };
pub const StatePredictionSimulationFn = *const fn (?*anyopaque, StatePredictionInput) bool;
pub const StatePredictionError = std.mem.Allocator.Error || error{ InvalidConfiguration, InputTooLarge, HistoryCapacityExceeded, SimulationRejected, SequenceExhausted };
pub const StatePredictionConfig = struct {
    maximum_history: usize,
    maximum_input_bytes: usize,
    simulation_context: ?*anyopaque,
    simulate: StatePredictionSimulationFn,
};
const HistoryRecord = struct {
    sequence: StatePredictionSequence,
    payload: core.OwnedBuffer,
    fn deinit(self: *HistoryRecord) void {
        self.payload.deinit();
        self.* = undefined;
    }
};
pub const StateClientPrediction = struct {
    allocator: std.mem.Allocator,
    config: StatePredictionConfig,
    history: std.ArrayListUnmanaged(HistoryRecord) = .empty,
    next_sequence: StatePredictionSequence = 0,

    pub fn init(allocator: std.mem.Allocator, config: StatePredictionConfig) StatePredictionError!StateClientPrediction {
        if (config.maximum_history == 0 or config.maximum_input_bytes == 0) return error.InvalidConfiguration;
        return .{ .allocator = allocator, .config = config };
    }
    pub fn deinit(self: *StateClientPrediction) void {
        for (self.history.items) |*record| record.deinit();
        self.history.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn submit(self: *StateClientPrediction, payload: []const u8) StatePredictionError!StatePredictionSequence {
        if (payload.len > self.config.maximum_input_bytes) return error.InputTooLarge;
        if (self.history.items.len == self.config.maximum_history) return error.HistoryCapacityExceeded;
        if (self.next_sequence == std.math.maxInt(StatePredictionSequence)) return error.SequenceExhausted;
        var owned = try core.OwnedBuffer.initCopy(self.allocator, payload);
        errdefer owned.deinit();
        const input = StatePredictionInput{ .sequence = self.next_sequence, .payload = owned.borrow() };
        if (!self.config.simulate(self.config.simulation_context, input)) return error.SimulationRejected;
        try self.history.append(self.allocator, .{ .sequence = self.next_sequence, .payload = owned });
        self.next_sequence += 1;
        return input.sequence;
    }
    pub fn acknowledge_through(self: *StateClientPrediction, sequence: StatePredictionSequence) void {
        var count: usize = 0;
        while (count < self.history.items.len and self.history.items[count].sequence <= sequence) : (count += 1) self.history.items[count].deinit();
        for (self.history.items[count..], 0..) |record, index| self.history.items[index] = record;
        self.history.items.len -= count;
    }
    pub fn pending(self: *const StateClientPrediction, output: []StatePredictionInput) usize {
        const count = @min(output.len, self.history.items.len);
        for (self.history.items[0..count], 0..) |record, index| output[index] = .{ .sequence = record.sequence, .payload = record.payload.borrow() };
        return count;
    }
};

test "client prediction simulates copied inputs and prunes acknowledged history" {
    const Fixture = struct {
        var simulated: usize = 0;
        fn simulate(_: ?*anyopaque, input: StatePredictionInput) bool {
            simulated += 1;
            return input.sequence < 2 and std.mem.eql(u8, input.payload.bytes, "x");
        }
    };
    Fixture.simulated = 0;
    var prediction = try StateClientPrediction.init(std.testing.allocator, .{ .maximum_history = 2, .maximum_input_bytes = 1, .simulation_context = null, .simulate = Fixture.simulate });
    defer prediction.deinit();
    try std.testing.expectEqual(@as(StatePredictionSequence, 0), try prediction.submit("x"));
    try std.testing.expectEqual(@as(StatePredictionSequence, 1), try prediction.submit("x"));
    var pending: [2]StatePredictionInput = undefined;
    try std.testing.expectEqual(@as(usize, 2), prediction.pending(pending[0..]));
    try std.testing.expectEqual(@as(StatePredictionSequence, 1), pending[1].sequence);
    prediction.acknowledge_through(0);
    try std.testing.expectEqual(@as(usize, 1), prediction.pending(pending[0..]));
    try std.testing.expectEqual(@as(usize, 2), Fixture.simulated);
}

test "client prediction rejects oversized full and failed simulation inputs" {
    const Fixture = struct {
        fn reject(_: ?*anyopaque, _: StatePredictionInput) bool {
            return false;
        }
    };
    var prediction = try StateClientPrediction.init(std.testing.allocator, .{ .maximum_history = 1, .maximum_input_bytes = 1, .simulation_context = null, .simulate = Fixture.reject });
    defer prediction.deinit();
    try std.testing.expectError(error.InputTooLarge, prediction.submit("xx"));
    try std.testing.expectError(error.SimulationRejected, prediction.submit("x"));
    try std.testing.expectError(error.InvalidConfiguration, StateClientPrediction.init(std.testing.allocator, .{ .maximum_history = 0, .maximum_input_bytes = 1, .simulation_context = null, .simulate = Fixture.reject }));
}
