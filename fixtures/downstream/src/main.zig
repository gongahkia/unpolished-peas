const core = @import("unpolished-peas");

pub fn main() !void {
    var clock = core.StepClock.init(60);
    if (clock.push(1.0 / 60.0) != 1 or clock.alpha() != 0) return error.InvalidStepClock;
    const color = core.Color.rgb(12, 34, 56);
    const bounds = core.Rect.init(0, 0, 4, 4);
    if (!bounds.contains(core.Vec2.init(2, 2)) or color.b != 56) return error.InvalidCoreValue;
}
