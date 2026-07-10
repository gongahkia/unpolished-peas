pub const App = @import("app.zig");
pub const AssetFile = @import("assets.zig").AssetFile;
pub const Canvas = @import("canvas.zig").Canvas;
pub const Color = @import("color.zig").Color;
pub const Input = @import("input.zig").Input;
pub const Key = @import("input.zig").Key;
pub const Rect = @import("math.zig").Rect;
pub const Sprite = @import("canvas.zig").Sprite;
pub const StepClock = @import("app.zig").StepClock;
pub const Vec2 = @import("math.zig").Vec2;

test {
    _ = @import("app.zig");
    _ = @import("assets.zig");
    _ = @import("canvas.zig");
    _ = @import("color.zig");
    _ = @import("input.zig");
    _ = @import("math.zig");
}
