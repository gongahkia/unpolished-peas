const std = @import("std");
const event = @import("event.zig");
const config = @import("sdk_config.zig");

pub const ManagedRuntimeError = error{ AlreadyStarted, NotRunning, QueueFull, ThreadSpawnFailed };

pub const ManagedRuntime = struct {
    allocator: std.mem.Allocator,
    sdk: config.Sdk,
    capacity: usize,
    mutex: std.Thread.Mutex = .{},
    ready: std.Thread.Condition = .{},
    worker: ?std.Thread = null,
    stopping: bool = false,
    queue: std.ArrayListUnmanaged(event.EventEnvelope) = .empty,
    processed: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, sdk: config.Sdk, capacity: usize) ManagedRuntime {
        return .{ .allocator = allocator, .sdk = sdk, .capacity = capacity };
    }

    pub fn start(self: *ManagedRuntime) ManagedRuntimeError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.worker != null) return error.AlreadyStarted;
        self.stopping = false;
        self.worker = std.Thread.spawn(.{}, run, .{self}) catch return error.ThreadSpawnFailed;
    }

    pub fn submit(self: *ManagedRuntime, envelope: event.EventEnvelope) (std.mem.Allocator.Error || ManagedRuntimeError)!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.worker == null or self.stopping) return error.NotRunning;
        if (self.queue.items.len == self.capacity) return error.QueueFull;
        try self.queue.append(self.allocator, envelope);
        self.ready.signal();
    }

    pub fn shutdown(self: *ManagedRuntime) ManagedRuntimeError!void {
        self.mutex.lock();
        const worker = self.worker orelse {
            self.mutex.unlock();
            return error.NotRunning;
        };
        self.stopping = true;
        self.ready.broadcast();
        self.mutex.unlock();
        worker.join();
        self.mutex.lock();
        self.worker = null;
        for (self.queue.items) |*queued_event| queued_event.deinit();
        self.queue.clearRetainingCapacity();
        self.mutex.unlock();
    }

    pub fn deinit(self: *ManagedRuntime) void {
        if (self.worker != null) _ = self.shutdown() catch {};
        self.queue.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn processed_count(self: *ManagedRuntime) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.processed;
    }

    fn run(self: *ManagedRuntime) void {
        self.mutex.lock();
        while (true) {
            while (!self.stopping and self.queue.items.len == 0) self.ready.wait(&self.mutex);
            if (self.stopping) break;
            const next = self.queue.items[0];
            for (self.queue.items[1..], 0..) |queued_event, index| self.queue.items[index] = queued_event;
            self.queue.items.len -= 1;
            self.mutex.unlock();
            var owned = next;
            owned.deinit();
            self.mutex.lock();
            self.processed +%= 1;
        }
        self.mutex.unlock();
    }
};

test "managed runtimes have explicit worker lifecycle and bounded submission" {
    var manual = @import("minna-san-core").ManualClock.init(0);
    const sdk = try config.SdkConfigBuilder.init().with_clock(manual.clock()).build();
    var runtime = ManagedRuntime.init(std.testing.allocator, sdk, 1);
    defer runtime.deinit();
    try runtime.start();
    try std.testing.expectError(error.AlreadyStarted, runtime.start());
    try runtime.submit(.{ .sequence = 0, .mode = .managed, .event = .{ .connected = {} } });
    var attempts: usize = 0;
    while (runtime.processed_count() != 1 and attempts < 100) : (attempts += 1) std.Thread.sleep(std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u64, 1), runtime.processed_count());
    try runtime.shutdown();
    var rejected = event.EventEnvelope{ .sequence = 1, .mode = .managed, .event = .{ .disconnected = {} } };
    defer rejected.deinit();
    try std.testing.expectError(error.NotRunning, runtime.submit(rejected));
}

test "managed runtimes reject submission when their queue is full" {
    var manual = @import("minna-san-core").ManualClock.init(0);
    const sdk = try config.SdkConfigBuilder.init().with_clock(manual.clock()).build();
    var runtime = ManagedRuntime.init(std.testing.allocator, sdk, 0);
    defer runtime.deinit();
    try runtime.start();
    var rejected = event.EventEnvelope{ .sequence = 0, .mode = .managed, .event = .{ .connected = {} } };
    defer rejected.deinit();
    try std.testing.expectError(error.QueueFull, runtime.submit(rejected));
}
