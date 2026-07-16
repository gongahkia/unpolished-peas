const up = @import("unpolished-peas");

pub fn main() !void {
    var clock = up.StepClock.init(60);
    if (clock.push(1.0 / 60.0) != 1) return error.InvalidReleaseConsumer;
}
