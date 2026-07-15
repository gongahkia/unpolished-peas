const std = @import("std");
const effects = @import("unpolished-peas-effects");

test "effects package is independent from core" {
    var resources = effects.Resources.init(std.testing.allocator);
    defer resources.deinit();
    const target = try resources.createRenderTarget();
    try resources.renderTarget(target);
}
