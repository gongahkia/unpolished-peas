const std = @import("std");
const effects = @import("unpolished-peas-effects");

test "effects package is independent from core" {
    var resources = effects.Resources.init(std.testing.allocator);
    defer resources.deinit();
    const target = try resources.createRenderTarget();
    try resources.renderTarget(target);
}

test "effects package compiles and applies post-process shaders" {
    const Color = struct { r: u8, g: u8, b: u8, a: u8 };
    const program = try effects.ShaderProgram.compile("effect=invert\nuniform amount:f32\n");
    var chain = effects.PostProcessChain{};
    try chain.append(try program.instantiate(.{}));
    try std.testing.expectEqual(Color{ .r = 245, .g = 235, .b = 225, .a = 255 }, chain.apply(Color{ .r = 10, .g = 20, .b = 30, .a = 255 }));
}
