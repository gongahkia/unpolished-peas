const std = @import("std");
const congestion = @import("congestion_controller.zig");

pub const max_backpressure_targets: usize = 64;
pub const BackpressureError = error{ InvalidConfiguration, TargetAlreadyRegistered, TargetCapacityExceeded, UnknownTarget, QueueFull, ReleaseExceedsQueued };

pub const BackpressureTarget = union(enum) {
    channel: u64,
    transport: congestion.RouteId,
};

pub const BackpressureState = enum {
    ready,
    pressured,
    saturated,
};

pub const BackpressureConfig = struct {
    maximum_queued_bytes: usize,
    high_watermark_bytes: usize,
};

pub const BackpressureSignal = struct {
    target: BackpressureTarget,
    state: BackpressureState,
    queued_bytes: usize,
    available_bytes: usize,
};

pub const BackpressureCallback = struct {
    context: *anyopaque,
    notify_fn: *const fn (*anyopaque, BackpressureSignal) void,

    pub fn notify(self: BackpressureCallback, signal: BackpressureSignal) void {
        self.notify_fn(self.context, signal);
    }
};

const TargetState = struct {
    target: BackpressureTarget,
    queued_bytes: usize = 0,
    state: BackpressureState = .ready,
    pending: bool = false,
};

pub const BackpressureController = struct {
    config: BackpressureConfig,
    callback: ?BackpressureCallback = null,
    targets: [max_backpressure_targets]?TargetState = .{null} ** max_backpressure_targets,

    pub fn init(config: BackpressureConfig) BackpressureError!BackpressureController {
        if (config.maximum_queued_bytes == 0 or config.high_watermark_bytes == 0 or config.high_watermark_bytes > config.maximum_queued_bytes) return error.InvalidConfiguration;
        return .{ .config = config };
    }

    pub fn set_callback(self: *BackpressureController, callback: ?BackpressureCallback) void {
        self.callback = callback;
    }

    pub fn register_target(self: *BackpressureController, target: BackpressureTarget) BackpressureError!void {
        if (self.target_ptr(target) != null) return error.TargetAlreadyRegistered;
        for (&self.targets) |*slot| {
            if (slot.* == null) {
                slot.* = .{ .target = target };
                return;
            }
        }
        return error.TargetCapacityExceeded;
    }

    pub fn remove_target(self: *BackpressureController, target: BackpressureTarget) BackpressureError!void {
        for (&self.targets) |*slot| {
            const state = slot.* orelse continue;
            if (eql_target(state.target, target)) {
                slot.* = null;
                return;
            }
        }
        return error.UnknownTarget;
    }

    pub fn reserve(self: *BackpressureController, target: BackpressureTarget, bytes: usize) BackpressureError!BackpressureSignal {
        const state = self.target_ptr(target) orelse return error.UnknownTarget;
        if (bytes > self.config.maximum_queued_bytes - state.queued_bytes) return error.QueueFull;
        state.queued_bytes += bytes;
        return self.update(state);
    }

    pub fn release(self: *BackpressureController, target: BackpressureTarget, bytes: usize) BackpressureError!BackpressureSignal {
        const state = self.target_ptr(target) orelse return error.UnknownTarget;
        if (bytes > state.queued_bytes) return error.ReleaseExceedsQueued;
        state.queued_bytes -= bytes;
        return self.update(state);
    }

    pub fn poll(self: *BackpressureController) ?BackpressureSignal {
        for (&self.targets) |*slot| {
            if (slot.*) |*state| {
                if (!state.pending) continue;
                state.pending = false;
                return self.signal(state.*);
            }
        }
        return null;
    }

    fn target_ptr(self: *BackpressureController, target: BackpressureTarget) ?*TargetState {
        for (&self.targets) |*slot| {
            const state = slot.* orelse continue;
            if (eql_target(state.target, target)) return &slot.*.?;
        }
        return null;
    }

    fn update(self: *BackpressureController, state: *TargetState) BackpressureSignal {
        const next = classify(self.config, state.queued_bytes);
        const current = self.signal(state.*);
        if (next == state.state) return current;
        state.state = next;
        const changed = self.signal(state.*);
        state.pending = true;
        if (self.callback) |callback| callback.notify(changed);
        return changed;
    }

    fn signal(self: BackpressureController, state: TargetState) BackpressureSignal {
        return .{
            .target = state.target,
            .state = state.state,
            .queued_bytes = state.queued_bytes,
            .available_bytes = self.config.maximum_queued_bytes - state.queued_bytes,
        };
    }
};

fn classify(config: BackpressureConfig, queued_bytes: usize) BackpressureState {
    if (queued_bytes == config.maximum_queued_bytes) return .saturated;
    if (queued_bytes >= config.high_watermark_bytes) return .pressured;
    return .ready;
}

fn eql_target(left: BackpressureTarget, right: BackpressureTarget) bool {
    return switch (left) {
        .channel => |channel| switch (right) {
            .channel => |other| channel == other,
            .transport => false,
        },
        .transport => |route| switch (right) {
            .channel => false,
            .transport => |other| route == other,
        },
    };
}

test "backpressure propagates channel pressure to callbacks and polling" {
    const Capture = struct {
        signals: [3]BackpressureSignal = undefined,
        count: usize = 0,

        fn callback(context: *anyopaque, signal: BackpressureSignal) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.signals[self.count] = signal;
            self.count += 1;
        }
    };
    var controller = try BackpressureController.init(.{ .maximum_queued_bytes = 8, .high_watermark_bytes = 6 });
    var capture = Capture{};
    controller.set_callback(.{ .context = &capture, .notify_fn = Capture.callback });
    try controller.register_target(.{ .channel = 5 });
    try std.testing.expectEqual(BackpressureState.pressured, (try controller.reserve(.{ .channel = 5 }, 6)).state);
    try std.testing.expectEqual(BackpressureState.saturated, (try controller.reserve(.{ .channel = 5 }, 2)).state);
    try std.testing.expectError(error.QueueFull, controller.reserve(.{ .channel = 5 }, 1));
    try std.testing.expectEqual(BackpressureState.ready, (try controller.release(.{ .channel = 5 }, 3)).state);
    try std.testing.expectEqual(@as(usize, 3), capture.count);
    try std.testing.expectEqual(BackpressureState.saturated, capture.signals[1].state);
    const polled = controller.poll().?;
    try std.testing.expectEqual(BackpressureState.ready, polled.state);
    try std.testing.expect((controller.poll()) == null);
}

test "backpressure tracks transport queues and validates lifecycle failures" {
    var controller = try BackpressureController.init(.{ .maximum_queued_bytes = 4, .high_watermark_bytes = 2 });
    try controller.register_target(.{ .transport = 9 });
    try std.testing.expectEqual(@as(usize, 2), (try controller.reserve(.{ .transport = 9 }, 2)).available_bytes);
    try std.testing.expectError(error.ReleaseExceedsQueued, controller.release(.{ .transport = 9 }, 3));
    try std.testing.expectError(error.TargetAlreadyRegistered, controller.register_target(.{ .transport = 9 }));
    try std.testing.expectError(error.UnknownTarget, controller.reserve(.{ .channel = 9 }, 1));
    try controller.remove_target(.{ .transport = 9 });
    try std.testing.expectError(error.UnknownTarget, controller.remove_target(.{ .transport = 9 }));
    try std.testing.expectError(error.InvalidConfiguration, BackpressureController.init(.{ .maximum_queued_bytes = 1, .high_watermark_bytes = 2 }));
}

test "backpressure bounds registered targets" {
    var controller = try BackpressureController.init(.{ .maximum_queued_bytes = 1, .high_watermark_bytes = 1 });
    for (0..max_backpressure_targets) |channel| try controller.register_target(.{ .channel = channel });
    try std.testing.expectError(error.TargetCapacityExceeded, controller.register_target(.{ .channel = max_backpressure_targets }));
}
