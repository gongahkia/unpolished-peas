const std = @import("std");

pub const StepClock = struct {
    step_seconds: f32,
    max_steps_per_frame: u32 = 5,
    accumulator: f32 = 0,

    pub fn init(fixed_hz: u32) StepClock {
        std.debug.assert(fixed_hz > 0);
        return .{ .step_seconds = 1 / @as(f32, @floatFromInt(fixed_hz)) };
    }

    pub fn push(self: *StepClock, dt_seconds: f32) u32 {
        self.accumulator += self.frameDelta(dt_seconds);

        var steps: u32 = 0;
        while (self.accumulator >= self.step_seconds and steps < self.max_steps_per_frame) {
            self.accumulator -= self.step_seconds;
            steps += 1;
        }
        if (steps == self.max_steps_per_frame and self.accumulator >= self.step_seconds) {
            self.accumulator = 0;
        }
        return steps;
    }

    pub fn frameDelta(self: StepClock, dt_seconds: f32) f32 {
        if (!(dt_seconds > 0)) return 0;
        const max_dt = self.step_seconds * @as(f32, @floatFromInt(self.max_steps_per_frame));
        return @min(dt_seconds, max_dt);
    }

    pub fn alpha(self: StepClock) f32 {
        if (self.step_seconds == 0) return 0;
        return self.accumulator / self.step_seconds;
    }
};

test "fixed clock accumulates clamped deltas and reports alpha" {
    var clock = StepClock.init(10);
    clock.max_steps_per_frame = 3;
    try std.testing.expectEqual(@as(f32, 0), clock.frameDelta(-1));
    try std.testing.expectEqual(@as(u32, 0), clock.push(0.05));
    try std.testing.expect(std.math.approxEqAbs(f32, 0.5, clock.alpha(), 0.0001));
    try std.testing.expectEqual(@as(u32, 1), clock.push(0.1));
    try std.testing.expect(std.math.approxEqAbs(f32, 0.5, clock.alpha(), 0.0001));
    try std.testing.expectEqual(@as(u32, 3), clock.push(1));
    try std.testing.expect(std.math.approxEqAbs(f32, 0.5, clock.alpha(), 0.0001));
}
