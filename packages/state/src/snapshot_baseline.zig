const std = @import("std");
const core = @import("minna-san-core");
const publisher = @import("snapshot_publisher.zig");

pub const StateSnapshotBaselineError = std.mem.Allocator.Error || error{ InvalidConfiguration, SnapshotTooLarge, InvalidSchemaVersion, OutOfOrderSnapshot, DuplicateSnapshot, BaselineCapacityExceeded, UnknownBaseline, BaselineNotAcknowledged };
pub const StateSnapshotBaseline = struct {
    sequence: publisher.StateSnapshotSequence,
    schema_version: u32,
    state: core.BorrowedBuffer,
    acknowledged: bool,
};
pub const StateSnapshotBaselineConfig = struct {
    maximum_baselines: usize,
    maximum_snapshot_bytes: usize,
};
const BaselineRecord = struct {
    sequence: publisher.StateSnapshotSequence,
    schema_version: u32,
    state: core.OwnedBuffer,
    acknowledged: bool = false,
    fn deinit(self: *BaselineRecord) void {
        self.state.deinit();
        self.* = undefined;
    }
};
pub const StateSnapshotBaselines = struct {
    allocator: std.mem.Allocator,
    config: StateSnapshotBaselineConfig,
    records: std.ArrayListUnmanaged(BaselineRecord) = .empty,

    pub fn init(allocator: std.mem.Allocator, config: StateSnapshotBaselineConfig) StateSnapshotBaselineError!StateSnapshotBaselines {
        if (config.maximum_baselines == 0 or config.maximum_snapshot_bytes == 0) return error.InvalidConfiguration;
        return .{ .allocator = allocator, .config = config };
    }
    pub fn deinit(self: *StateSnapshotBaselines) void {
        for (self.records.items) |*record| record.deinit();
        self.records.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn track(self: *StateSnapshotBaselines, snapshot: publisher.StateSnapshot) StateSnapshotBaselineError!void {
        if (snapshot.schema_version == 0) return error.InvalidSchemaVersion;
        if (snapshot.state.bytes.len > self.config.maximum_snapshot_bytes) return error.SnapshotTooLarge;
        if (self.records.items.len != 0) {
            const latest = self.records.items[self.records.items.len - 1].sequence;
            if (snapshot.sequence == latest) return error.DuplicateSnapshot;
            if (snapshot.sequence < latest) return error.OutOfOrderSnapshot;
        }
        var state = try core.OwnedBuffer.initCopy(self.allocator, snapshot.state.bytes);
        errdefer state.deinit();
        try self.records.ensureUnusedCapacity(self.allocator, 1);
        if (self.records.items.len == self.config.maximum_baselines) {
            if (!self.records.items[0].acknowledged) return error.BaselineCapacityExceeded;
            self.records.items[0].deinit();
            _ = self.records.orderedRemove(0);
        }
        self.records.appendAssumeCapacity(.{ .sequence = snapshot.sequence, .schema_version = snapshot.schema_version, .state = state });
    }
    pub fn acknowledge(self: *StateSnapshotBaselines, sequence: publisher.StateSnapshotSequence) StateSnapshotBaselineError!void {
        const index = self.index_of(sequence) orelse return error.UnknownBaseline;
        self.records.items[index].acknowledged = true;
    }
    pub fn select(self: *const StateSnapshotBaselines) ?StateSnapshotBaseline {
        var index = self.records.items.len;
        while (index != 0) {
            index -= 1;
            const record = self.records.items[index];
            if (record.acknowledged) return .{ .sequence = record.sequence, .schema_version = record.schema_version, .state = record.state.borrow(), .acknowledged = true };
        }
        return null;
    }
    pub fn evict(self: *StateSnapshotBaselines, sequence: publisher.StateSnapshotSequence) StateSnapshotBaselineError!void {
        const index = self.index_of(sequence) orelse return error.UnknownBaseline;
        if (!self.records.items[index].acknowledged) return error.BaselineNotAcknowledged;
        self.records.items[index].deinit();
        _ = self.records.orderedRemove(index);
    }
    fn index_of(self: *const StateSnapshotBaselines, sequence: publisher.StateSnapshotSequence) ?usize {
        for (self.records.items, 0..) |record, index| if (record.sequence == sequence) return index;
        return null;
    }
};

test "snapshot baselines retain acknowledge select and evict owned snapshots" {
    var baselines = try StateSnapshotBaselines.init(std.testing.allocator, .{ .maximum_baselines = 2, .maximum_snapshot_bytes = 2 });
    defer baselines.deinit();
    try baselines.track(.{ .sequence = 0, .schema_version = 1, .state = .init("a") });
    try baselines.track(.{ .sequence = 1, .schema_version = 1, .state = .init("b") });
    try std.testing.expect(baselines.select() == null);
    try baselines.acknowledge(0);
    try std.testing.expectEqual(@as(publisher.StateSnapshotSequence, 0), baselines.select().?.sequence);
    try baselines.acknowledge(1);
    const selected = baselines.select().?;
    try std.testing.expectEqual(@as(publisher.StateSnapshotSequence, 1), selected.sequence);
    try std.testing.expectEqualStrings("b", selected.state.bytes);
    try baselines.track(.{ .sequence = 2, .schema_version = 1, .state = .init("c") });
    try std.testing.expectEqual(@as(publisher.StateSnapshotSequence, 1), baselines.select().?.sequence);
    try baselines.evict(1);
    try std.testing.expect(baselines.select() == null);
}

test "snapshot baselines reject invalid unordered capacity and unacknowledged eviction" {
    try std.testing.expectError(error.InvalidConfiguration, StateSnapshotBaselines.init(std.testing.allocator, .{ .maximum_baselines = 0, .maximum_snapshot_bytes = 1 }));
    var baselines = try StateSnapshotBaselines.init(std.testing.allocator, .{ .maximum_baselines = 1, .maximum_snapshot_bytes = 1 });
    defer baselines.deinit();
    try std.testing.expectError(error.InvalidSchemaVersion, baselines.track(.{ .sequence = 0, .schema_version = 0, .state = .init("x") }));
    try std.testing.expectError(error.SnapshotTooLarge, baselines.track(.{ .sequence = 0, .schema_version = 1, .state = .init("xx") }));
    try baselines.track(.{ .sequence = 1, .schema_version = 1, .state = .init("x") });
    try std.testing.expectError(error.DuplicateSnapshot, baselines.track(.{ .sequence = 1, .schema_version = 1, .state = .init("x") }));
    try std.testing.expectError(error.OutOfOrderSnapshot, baselines.track(.{ .sequence = 0, .schema_version = 1, .state = .init("x") }));
    try std.testing.expectError(error.BaselineNotAcknowledged, baselines.evict(1));
    try std.testing.expectError(error.BaselineCapacityExceeded, baselines.track(.{ .sequence = 2, .schema_version = 1, .state = .init("x") }));
}
