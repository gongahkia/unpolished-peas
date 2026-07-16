const up = @import("unpolished-peas");

pub export fn facade_probe() i32 {
    const point = up.Vec2.init(3, 4);
    const bounds = up.Rect.init(0, 0, 8, 8);
    return @intFromBool(bounds.contains(point) and up.Color.rgb(1, 2, 3).b == 3);
}
