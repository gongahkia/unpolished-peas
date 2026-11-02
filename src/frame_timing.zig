const std = @import("std");
const up = @import("unpolished-peas");

pub const default_fixed_hz: u32 = 60;

/// Shared host-side buffering. A presentation frame can run zero or several
/// simulation ticks; only the first tick consumes accumulated input edges.
/// This stays outside the game's public Input API.
pub const TickBuffer = struct {
    pending: up.input.Input.Snapshot = .{},

    pub fn submit(self: *TickBuffer, state: up.input.Input) void {
        self.pending.merge(state.snapshot());
    }

    pub fn next(self: *TickBuffer) up.input.Input.Snapshot {
        const result = self.pending;
        self.pending.clearTransient();
        return result;
    }

    pub fn reset(self: *TickBuffer) void {
        self.* = .{};
    }
};

pub const FrameTiming = struct {
    update_steps: u32,
    update_seconds: f32,
    draw_seconds: f32,
    alpha: f32,
};

pub const Scheduler = struct {
    clock: up.core.StepClock,

    pub fn init(fixed_hz: u32) Scheduler {
        return .{ .clock = up.core.StepClock.init(fixed_hz) };
    }

    pub fn frame(self: *Scheduler, elapsed_seconds: f32, paused: bool) FrameTiming {
        if (paused) return .{ .update_steps = 0, .update_seconds = self.clock.step_seconds, .draw_seconds = 0, .alpha = 0 };
        const draw_seconds = self.clock.frameDelta(elapsed_seconds);
        return .{ .update_steps = self.clock.push(draw_seconds), .update_seconds = self.clock.step_seconds, .draw_seconds = draw_seconds, .alpha = self.clock.alpha() };
    }
};

test "scheduler bounds long frames and preserves paused state" {
    var scheduler = Scheduler.init(10);
    scheduler.clock.max_steps_per_frame = 3;
    const first = scheduler.frame(0.05, false);
    try std.testing.expectEqual(@as(u32, 0), first.update_steps);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), first.alpha, 0.0001);
    const second = scheduler.frame(0.1, false);
    try std.testing.expectEqual(@as(u32, 1), second.update_steps);
    const long_frame = scheduler.frame(1, false);
    try std.testing.expectEqual(@as(u32, 3), long_frame.update_steps);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), long_frame.alpha, 0.0001);
    const paused = scheduler.frame(1, true);
    try std.testing.expectEqual(@as(u32, 0), paused.update_steps);
    try std.testing.expectEqual(@as(f32, 0), paused.draw_seconds);
    try std.testing.expectEqual(@as(f32, 0), paused.alpha);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), scheduler.clock.alpha(), 0.0001);
}

test "hosts retain taps through zero-update and paused frames then consume edges once" {
    var scheduler = Scheduler.init(10);
    var buffer = TickBuffer{};
    var input = up.input.Input{};
    input.set(.action, true);
    input.setPointerButton(.left, true);
    input.addPointerWheel(.{ .y = 2 });
    buffer.submit(input);
    try std.testing.expectEqual(@as(u32, 0), scheduler.frame(0.05, false).update_steps);
    input.beginFrame();
    input.releaseAll(); // focus loss before the next fixed update
    buffer.submit(input);
    try std.testing.expectEqual(@as(u32, 0), scheduler.frame(10, true).update_steps);
    input.beginFrame();
    buffer.submit(input);
    const resumed = scheduler.frame(0.3, false);
    try std.testing.expectEqual(@as(u32, 3), resumed.update_steps);
    for (0..resumed.update_steps) |tick| {
        var observed = up.input.Input{};
        buffer.next().apply(&observed);
        try std.testing.expect(!observed.isDown(.action));
        try std.testing.expect(!observed.pointerIsDown(.left));
        try std.testing.expectEqual(tick == 0, observed.wasPressed(.action));
        try std.testing.expectEqual(tick == 0, observed.wasReleased(.action));
        try std.testing.expectEqual(tick == 0, observed.pointerWasReleased(.left));
        try std.testing.expectEqual(@as(f32, if (tick == 0) 2 else 0), observed.pointer.wheel.y);
    }
    buffer.reset();
    try std.testing.expectEqualDeep(up.input.Input.Snapshot{}, buffer.next());
}
