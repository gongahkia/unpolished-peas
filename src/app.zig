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
        if (dt_seconds <= 0) return 0;

        const max_dt = self.step_seconds * @as(f32, @floatFromInt(self.max_steps_per_frame));
        self.accumulator += @min(dt_seconds, max_dt);

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

    pub fn alpha(self: StepClock) f32 {
        if (self.step_seconds == 0) return 0;
        return self.accumulator / self.step_seconds;
    }
};

test "fixed clock" {
    var clock = StepClock.init(60);
    try std.testing.expectEqual(@as(u32, 0), clock.push(1.0 / 120.0));
    try std.testing.expectEqual(@as(u32, 1), clock.push(1.0 / 120.0));
    try std.testing.expect(clock.alpha() >= 0 and clock.alpha() < 1);
}
