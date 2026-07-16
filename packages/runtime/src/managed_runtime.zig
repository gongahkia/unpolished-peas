const std = @import("std");
const event = @import("event.zig");
const config = @import("sdk_config.zig");

threadlocal var direct_callback_active: bool = false;

pub const DirectDispatch = struct {
    context: *anyopaque,
    callback: *const fn (*anyopaque, *const event.EventEnvelope) void,
};

pub const ManagedRuntimeError = error{ AlreadyStarted, NotRunning, QueueFull, ThreadSpawnFailed, ReentrantCall, NotCallerDrained, DrainThreadMismatch };

pub const ManagedRuntime = struct {
    allocator: std.mem.Allocator,
    sdk: config.Sdk,
    capacity: usize,
    mutex: std.Thread.Mutex = .{},
    ready: std.Thread.Condition = .{},
    worker: ?std.Thread = null,
    stopping: bool = false,
    direct_dispatch: ?DirectDispatch = null,
    caller_drained: bool = false,
    drain_thread: ?std.Thread.Id = null,
    queue: std.ArrayListUnmanaged(event.EventEnvelope) = .empty,
    processed: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, sdk: config.Sdk, capacity: usize) ManagedRuntime {
        return .{ .allocator = allocator, .sdk = sdk, .capacity = capacity };
    }

    pub fn init_with_direct_dispatch(allocator: std.mem.Allocator, sdk: config.Sdk, capacity: usize, dispatch: DirectDispatch) ManagedRuntime {
        return .{ .allocator = allocator, .sdk = sdk, .capacity = capacity, .direct_dispatch = dispatch };
    }

    pub fn init_with_caller_drain(allocator: std.mem.Allocator, sdk: config.Sdk, capacity: usize) ManagedRuntime {
        return .{ .allocator = allocator, .sdk = sdk, .capacity = capacity, .caller_drained = true };
    }

    pub fn start(self: *ManagedRuntime) ManagedRuntimeError!void {
        if (direct_callback_active) return error.ReentrantCall;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.worker != null) return error.AlreadyStarted;
        self.stopping = false;
        self.worker = std.Thread.spawn(.{}, run, .{self}) catch return error.ThreadSpawnFailed;
    }

    pub fn submit(self: *ManagedRuntime, envelope: event.EventEnvelope) (std.mem.Allocator.Error || ManagedRuntimeError)!void {
        if (direct_callback_active) return error.ReentrantCall;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.worker == null or self.stopping) return error.NotRunning;
        if (self.queue.items.len == self.capacity) return error.QueueFull;
        try self.queue.append(self.allocator, envelope);
        self.ready.signal();
    }

    pub fn shutdown(self: *ManagedRuntime) ManagedRuntimeError!void {
        if (direct_callback_active) return error.ReentrantCall;
        self.mutex.lock();
        if (self.stopping) {
            self.mutex.unlock();
            return error.NotRunning;
        }
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

    pub fn drain(self: *ManagedRuntime) ManagedRuntimeError!?event.EventEnvelope {
        if (direct_callback_active) return error.ReentrantCall;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.stopping or self.worker == null) return error.NotRunning;
        if (!self.caller_drained) return error.NotCallerDrained;
        const current_thread = std.Thread.getCurrentId();
        if (self.drain_thread) |thread_id| {
            if (thread_id != current_thread) return error.DrainThreadMismatch;
        } else {
            self.drain_thread = current_thread;
        }
        if (self.queue.items.len == 0) return null;
        const next = self.queue.items[0];
        for (self.queue.items[1..], 0..) |queued_event, index| self.queue.items[index] = queued_event;
        self.queue.items.len -= 1;
        self.processed +%= 1;
        return next;
    }

    fn run(self: *ManagedRuntime) void {
        self.mutex.lock();
        if (self.caller_drained) {
            while (!self.stopping) self.ready.wait(&self.mutex);
            self.mutex.unlock();
            return;
        }
        while (true) {
            while (!self.stopping and self.queue.items.len == 0) self.ready.wait(&self.mutex);
            if (self.stopping) break;
            const next = self.queue.items[0];
            for (self.queue.items[1..], 0..) |queued_event, index| self.queue.items[index] = queued_event;
            self.queue.items.len -= 1;
            self.mutex.unlock();
            var owned = next;
            if (self.direct_dispatch) |dispatch| {
                {
                    direct_callback_active = true;
                    defer direct_callback_active = false;
                    dispatch.callback(dispatch.context, &owned);
                }
            }
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

test "caller-drained runtimes bind deterministic drains to one thread" {
    const WrongThread = struct {
        runtime: *ManagedRuntime,
        mutex: std.Thread.Mutex = .{},
        result: ?ManagedRuntimeError = null,

        fn run(context: *@This()) void {
            _ = context.runtime.drain() catch |err| {
                context.mutex.lock();
                defer context.mutex.unlock();
                context.result = err;
                return;
            };
        }
    };
    var manual = @import("minna-san-core").ManualClock.init(0);
    const sdk = try config.SdkConfigBuilder.init().with_clock(manual.clock()).build();
    var runtime = ManagedRuntime.init_with_caller_drain(std.testing.allocator, sdk, 1);
    defer runtime.deinit();
    try runtime.start();
    try std.testing.expect((try runtime.drain()) == null);
    try runtime.submit(.{ .sequence = 0, .mode = .managed, .event = .{ .connected = {} } });
    var drained = (try runtime.drain()).?;
    defer drained.deinit();
    try std.testing.expectEqual(@as(u64, 1), runtime.processed_count());
    var wrong_thread = WrongThread{ .runtime = &runtime };
    const worker = try std.Thread.spawn(.{}, WrongThread.run, .{&wrong_thread});
    worker.join();
    wrong_thread.mutex.lock();
    defer wrong_thread.mutex.unlock();
    try std.testing.expectEqual(error.DrainThreadMismatch, wrong_thread.result.?);
}

test "non-caller-drained runtimes reject caller draining" {
    var manual = @import("minna-san-core").ManualClock.init(0);
    const sdk = try config.SdkConfigBuilder.init().with_clock(manual.clock()).build();
    var runtime = ManagedRuntime.init(std.testing.allocator, sdk, 1);
    defer runtime.deinit();
    try std.testing.expectError(error.NotCallerDrained, runtime.drain());
}

test "direct dispatch runs on workers and rejects reentrant runtime mutation" {
    const Capture = struct {
        mutex: std.Thread.Mutex = .{},
        callbacks: usize = 0,
        reentrant_rejected: bool = false,
        runtime: ?*ManagedRuntime = null,

        fn callback(context: *anyopaque, _: *const event.EventEnvelope) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            var rejected = event.EventEnvelope{ .sequence = 1, .mode = .managed, .event = .{ .disconnected = {} } };
            _ = self.runtime.?.submit(rejected) catch |err| {
                rejected.deinit();
                self.mutex.lock();
                defer self.mutex.unlock();
                self.callbacks += 1;
                self.reentrant_rejected = err == error.ReentrantCall;
                return;
            };
            unreachable;
        }
    };
    var manual = @import("minna-san-core").ManualClock.init(0);
    const sdk = try config.SdkConfigBuilder.init().with_clock(manual.clock()).build();
    var capture = Capture{};
    var runtime = ManagedRuntime.init_with_direct_dispatch(std.testing.allocator, sdk, 1, .{ .context = &capture, .callback = Capture.callback });
    capture.runtime = &runtime;
    defer runtime.deinit();
    try runtime.start();
    try runtime.submit(.{ .sequence = 0, .mode = .managed, .event = .{ .connected = {} } });
    var attempts: usize = 0;
    while (runtime.processed_count() != 1 and attempts < 100) : (attempts += 1) std.Thread.sleep(std.time.ns_per_ms);
    capture.mutex.lock();
    defer capture.mutex.unlock();
    try std.testing.expectEqual(@as(usize, 1), capture.callbacks);
    try std.testing.expect(capture.reentrant_rejected);
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

test "concurrent shutdown has one owner and leaves the runtime stopped" {
    const Shutdown = struct {
        runtime: *ManagedRuntime,
        mutex: std.Thread.Mutex = .{},
        succeeded: bool = false,
        result: ?ManagedRuntimeError = null,

        fn run(context: *@This()) void {
            context.runtime.shutdown() catch |err| {
                context.mutex.lock();
                defer context.mutex.unlock();
                context.result = err;
                return;
            };
            context.mutex.lock();
            defer context.mutex.unlock();
            context.succeeded = true;
        }
    };
    var manual = @import("minna-san-core").ManualClock.init(0);
    const sdk = try config.SdkConfigBuilder.init().with_clock(manual.clock()).build();
    var runtime = ManagedRuntime.init(std.testing.allocator, sdk, 1);
    defer runtime.deinit();
    try runtime.start();
    var first = Shutdown{ .runtime = &runtime };
    var second = Shutdown{ .runtime = &runtime };
    const first_thread = try std.Thread.spawn(.{}, Shutdown.run, .{&first});
    const second_thread = try std.Thread.spawn(.{}, Shutdown.run, .{&second});
    first_thread.join();
    second_thread.join();
    first.mutex.lock();
    defer first.mutex.unlock();
    second.mutex.lock();
    defer second.mutex.unlock();
    try std.testing.expect(@intFromBool(first.succeeded) + @intFromBool(second.succeeded) == 1);
    if (!first.succeeded) try std.testing.expectEqual(error.NotRunning, first.result.?);
    if (!second.succeeded) try std.testing.expectEqual(error.NotRunning, second.result.?);
    var rejected = event.EventEnvelope{ .sequence = 0, .mode = .managed, .event = .{ .connected = {} } };
    defer rejected.deinit();
    try std.testing.expectError(error.NotRunning, runtime.submit(rejected));
}

test "caller draining stops with managed runtime shutdown" {
    var manual = @import("minna-san-core").ManualClock.init(0);
    const sdk = try config.SdkConfigBuilder.init().with_clock(manual.clock()).build();
    var runtime = ManagedRuntime.init_with_caller_drain(std.testing.allocator, sdk, 1);
    defer runtime.deinit();
    try runtime.start();
    try runtime.shutdown();
    try std.testing.expectError(error.NotRunning, runtime.drain());
}
