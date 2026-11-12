//! Verification-only bounded observations; no allocation, logging or policy changes.
const std = @import("std");
const up = @import("unpolished-peas");
const Store = up.core.SaveStore;
pub const Clock = struct {
    context: *anyopaque,
    read: *const fn (*anyopaque) u64,
    fn now(self: Clock) u64 {
        return self.read(self.context);
    }
};
pub const Update = struct { tick: usize, start_ns: u64, end_ns: u64 };
pub const Kind = enum { read_size, read, write, delete, exists };
pub const Operation = struct { tick: ?usize, kind: Kind, start_ns: u64, end_ns: u64, bytes: usize, failure: ?[]const u8 };
pub const Collector = struct {
    clock: Clock,
    enabled: bool = true,
    updates: []Update,
    operations: []Operation,
    update_count: usize = 0,
    operation_count: usize = 0,
    dropped_updates: usize = 0,
    dropped_operations: usize = 0,
    active_tick: ?usize = null,
    pub fn beginUpdate(self: *Collector, tick: usize) u64 {
        if (!self.enabled) return 0;
        std.debug.assert(self.active_tick == null);
        self.active_tick = tick;
        return self.clock.now();
    }
    pub fn endUpdate(self: *Collector, started: u64) void {
        if (!self.enabled) return;
        const value = Update{ .tick = self.active_tick.?, .start_ns = started, .end_ns = self.clock.now() };
        self.active_tick = null;
        if (self.update_count == self.updates.len) {
            self.dropped_updates += 1;
            return;
        }
        self.updates[self.update_count] = value;
        self.update_count += 1;
    }
    fn finish(self: *Collector, kind: Kind, started: u64, bytes: usize, failure: ?Store.Error) void {
        if (!self.enabled) return;
        const value = Operation{ .tick = self.active_tick, .kind = kind, .start_ns = started, .end_ns = self.clock.now(), .bytes = bytes, .failure = if (failure) |err| @errorName(err) else null };
        if (self.operation_count == self.operations.len) {
            self.dropped_operations += 1;
            return;
        }
        self.operations[self.operation_count] = value;
        self.operation_count += 1;
    }
    fn start(self: *Collector) u64 {
        return if (self.enabled) self.clock.now() else 0;
    }
};
pub const Wrapper = struct {
    parent: *Store,
    collector: *Collector,
    store: Store = undefined,
    const vtable: Store.VTable = .{ .read_size = readSize, .read = read, .write = write, .delete = delete, .exists = exists };
    pub fn capability(self: *Wrapper) *Store {
        self.store = Store.init(self, &vtable);
        return &self.store;
    }
    fn readSize(context: *anyopaque, key: []const u8) Store.Error!usize {
        const self: *Wrapper = @ptrCast(@alignCast(context));
        const started = self.collector.start();
        const size = self.parent.vtable.read_size(self.parent.context, key) catch |err| {
            self.collector.finish(.read_size, started, 0, err);
            return err;
        };
        self.collector.finish(.read_size, started, size, null);
        return size;
    }
    fn read(context: *anyopaque, key: []const u8, destination: []u8) Store.Error!usize {
        const self: *Wrapper = @ptrCast(@alignCast(context));
        const started = self.collector.start();
        const count = self.parent.vtable.read(self.parent.context, key, destination) catch |err| {
            self.collector.finish(.read, started, 0, err);
            return err;
        };
        self.collector.finish(.read, started, count, null);
        return count;
    }
    fn write(context: *anyopaque, key: []const u8, bytes: []const u8) Store.Error!void {
        const self: *Wrapper = @ptrCast(@alignCast(context));
        const started = self.collector.start();
        self.parent.vtable.write(self.parent.context, key, bytes) catch |err| {
            self.collector.finish(.write, started, bytes.len, err);
            return err;
        };
        self.collector.finish(.write, started, bytes.len, null);
    }
    fn delete(context: *anyopaque, key: []const u8) Store.Error!void {
        const self: *Wrapper = @ptrCast(@alignCast(context));
        const started = self.collector.start();
        self.parent.vtable.delete(self.parent.context, key) catch |err| {
            self.collector.finish(.delete, started, 0, err);
            return err;
        };
        self.collector.finish(.delete, started, 0, null);
    }
    fn exists(context: *anyopaque, key: []const u8) Store.Error!bool {
        const self: *Wrapper = @ptrCast(@alignCast(context));
        const started = self.collector.start();
        const found = self.parent.vtable.exists(self.parent.context, key) catch |err| {
            self.collector.finish(.exists, started, 0, err);
            return err;
        };
        self.collector.finish(.exists, started, 0, null);
        return found;
    }
};
pub const Capture = struct {
    updates: [2048]Update = undefined,
    operations: [256]Operation = undefined,
    timer: std.time.Timer = undefined,
    collector: Collector = undefined,
    pub fn init(self: *Capture) !void {
        // Commit observer pages before the measured window as well as reserving them.
        @memset(std.mem.asBytes(&self.updates), 0);
        @memset(std.mem.asBytes(&self.operations), 0);
        self.timer = try std.time.Timer.start();
        self.collector = .{ .clock = .{ .context = &self.timer, .read = now }, .updates = &self.updates, .operations = &self.operations };
    }
    fn now(context: *anyopaque) u64 {
        const timer: *std.time.Timer = @ptrCast(@alignCast(context));
        return timer.read();
    }
};
test "bounded observer associates ticks, reports overflow, preserves errors and disables clocks" {
    const Fake = struct {
        time: u64 = 0,
        fn now(p: *anyopaque) u64 {
            const self: *@This() = @ptrCast(@alignCast(p));
            self.time += 10;
            return self.time;
        }
    };
    var clock = Fake{};
    var updates: [2]Update = undefined;
    var operations: [8]Operation = undefined;
    var collector = Collector{ .clock = .{ .context = &clock, .read = Fake.now }, .updates = &updates, .operations = &operations };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var parent: up.testSupport.InMemorySaveStore = undefined;
    parent.init(failing.allocator());
    defer parent.deinit();
    var wrapper = Wrapper{ .parent = parent.capability(), .collector = &collector };
    const store = wrapper.capability();
    var started = collector.beginUpdate(555);
    try store.write("journey", "old");
    collector.endUpdate(started);
    try std.testing.expectEqual(Update{ .tick = 555, .start_ns = 10, .end_ns = 40 }, updates[0]);
    try std.testing.expectEqual(@as(?usize, 555), operations[0].tick);
    try std.testing.expectEqual(@as(u64, 20), operations[0].start_ns);
    try std.testing.expectEqual(@as(u64, 30), operations[0].end_ns);
    failing.fail_index = failing.alloc_index;
    started = collector.beginUpdate(556);
    try std.testing.expectError(error.OutOfMemory, store.write("journey", "replacement"));
    collector.endUpdate(started);
    try std.testing.expectEqualStrings("OutOfMemory", operations[1].failure.?);
    var bytes: [32]u8 = undefined;
    try std.testing.expectEqualStrings("old", try store.read("journey", &bytes));
    try std.testing.expect(operations[2].tick == null);
    try std.testing.expectError(error.TooLarge, store.read("journey", bytes[0..1]));
    failing.fail_index = std.math.maxInt(usize);
    const loaded = try store.readAlloc(std.testing.allocator, "journey", 32);
    defer std.testing.allocator.free(loaded);
    try std.testing.expectEqualStrings("old", loaded);
    try std.testing.expect(try store.exists("journey"));
    try store.delete("journey");
    try std.testing.expectError(error.NotFound, store.read("journey", &bytes));
    try std.testing.expectEqual(@as(usize, 1), collector.dropped_operations);
    started = collector.beginUpdate(557);
    collector.endUpdate(started);
    try std.testing.expectEqual(@as(usize, 1), collector.dropped_updates);
    const before = clock.time;
    collector.enabled = false;
    started = collector.beginUpdate(558);
    try store.write("journey", "retry");
    collector.endUpdate(started);
    try std.testing.expectEqualStrings("retry", try store.read("journey", &bytes));
    try std.testing.expectEqual(before, clock.time);
    try std.testing.expectEqual(@as(usize, 2), collector.update_count);
    try std.testing.expectEqual(@as(usize, 8), collector.operation_count);
}

test "observed replay keeps gameplay and saved bytes identical to unwrapped play" {
    const game = @import("game.zig");
    const saves = @import("save.zig");
    const digest = @import("profile_state.zig").digest;
    const Runner = up.testSupport.HeadlessGameRunner(game.Game);
    const allocator = std.testing.allocator;
    var first_store: up.testSupport.InMemorySaveStore = undefined;
    first_store.init(allocator);
    defer first_store.deinit();
    const baseline = try Runner.initSeededWithSaveData(allocator, game.width, game.height, game.default_seed, first_store.capability());
    defer baseline.deinit();
    var recorder = try up.preview.developer.InputReplayRecorder.initSeeded(allocator, 60, game.default_seed);
    defer recorder.deinit();
    var expected: [300]u64 = undefined;
    var input = up.input.Input{};
    for (&expected, 0..) |*value, tick| {
        input.beginFrame();
        input.set(.start, tick == 0);
        input.set(.right, tick > 10 and tick < 80);
        input.setPhysical(.j, tick == 100, false);
        try recorder.record(input);
        try baseline.step(input.snapshot(), 1.0 / 60.0);
        value.* = digest(&baseline.game);
    }
    var replay = try recorder.finish();
    defer replay.deinit(allocator);
    const bytes = try replay.encode(allocator);
    defer allocator.free(bytes);
    var decoded = try up.preview.developer.parseInputReplay(allocator, bytes);
    defer decoded.deinit(allocator);
    var second_store: up.testSupport.InMemorySaveStore = undefined;
    second_store.init(allocator);
    defer second_store.deinit();
    var capture: Capture = undefined;
    try capture.init();
    capture.collector.enabled = false;
    var wrapper = Wrapper{ .parent = second_store.capability(), .collector = &capture.collector };
    const observed = try Runner.initSeededWithSaveData(allocator, game.width, game.height, game.default_seed, wrapper.capability());
    defer observed.deinit();
    capture.collector.enabled = true;
    for (decoded.frames, 0..) |frame, tick| {
        const started = capture.collector.beginUpdate(tick);
        try observed.step(frame, 1.0 / 60.0);
        capture.collector.endUpdate(started);
        try std.testing.expectEqual(expected[tick], digest(&observed.game));
    }
    var one: [saves.size]u8 = undefined;
    var two: [saves.size]u8 = undefined;
    try std.testing.expectEqualSlices(u8, try first_store.capability().read(saves.key, &one), try second_store.capability().read(saves.key, &two));
    try std.testing.expectEqual(@as(usize, 0), capture.collector.dropped_operations);
    try std.testing.expectEqual(@as(usize, 0), capture.collector.dropped_updates);
    try std.testing.expect(capture.collector.operation_count > 0);
}
