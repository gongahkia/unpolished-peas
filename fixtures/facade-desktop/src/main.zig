const std = @import("std");
const up = @import("unpolished-peas");

const ProtocolGame = struct {
    pub fn init(_: *@This(), _: *up.core.GameContext) !void {}
    pub fn update(_: *@This(), _: *up.core.GameContext, _: f32) !void {}
    pub fn draw(_: *@This(), _: *up.core.GameContext) !void {}
};

comptime {
    _ = up.core.GameProtocol(ProtocolGame);
}

fn probe() bool {
    const point = up.core.Vec2.init(3, 4);
    const bounds = up.core.Rect.init(0, 0, 8, 8);
    return bounds.contains(point) and up.core.Color.rgb(1, 2, 3).g == 2;
}

pub fn main() !void {
    if (!probe()) return error.FacadeProbeFailed;
}

test "desktop consumer uses only the cohesive facade" {
    try std.testing.expect(probe());
}
