const std = @import("std");
const up = @import("unpolished-peas");

pub const default_fixed_hz: u32 = 60;

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
