const std = @import("std");
const core = @import("unpolished-peas").api;
const effects = @import("unpolished-peas-effects");
const lighting = effects.lighting(core);

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

test "effects lighting validates bounds and renders through core contracts" {
    try std.testing.expectError(error.InvalidLightingConfig, lighting.Pipeline.init(std.testing.allocator, .{ .max_lights = 0 }));
    var pipeline = try lighting.Pipeline.init(std.testing.allocator, .{ .max_lights = 1, .max_occluders = 1 });
    defer pipeline.deinit();
    try std.testing.expectError(error.InvalidLightBounds, pipeline.addLight(.{ .position = .{ .x = std.math.inf(f32) }, .radius = 1 }));
    try pipeline.addLight(.{ .position = .{ .x = 1.5, .y = 0.5 }, .radius = 2, .color = .rgb(255, 128, 0) });
    try pipeline.addOccluder(.{ .bounds = .init(0.25, 0, 0.5, 1) });

    var canvas = try core.Canvas.init(std.testing.allocator, 4, 1);
    defer canvas.deinit();
    canvas.clear(core.Color.black);
    var camera = core.Camera2D{ .position = .{ .x = 1.5, .y = 0.5 } };
    const metrics = pipeline.render(.init(&canvas, &camera));
    try std.testing.expectEqual(lighting.RenderPath.headless_fallback, metrics.path);
    try std.testing.expect(metrics.lit_pixels > 0);

    var commands = core.RenderCommandBuffer.init(std.testing.allocator);
    defer commands.deinit();
    const command_metrics = try pipeline.append(&commands, &camera, .{ .x = 4, .y = 1 });
    try std.testing.expectEqual(lighting.RenderPath.gpu_primitives, command_metrics.path);
    try std.testing.expectEqual(lighting.RenderPath.gpu_primitives, lighting.Pipeline.preferredPath(true));
    try std.testing.expectEqual(lighting.RenderPath.headless_fallback, lighting.Pipeline.preferredPath(false));
}
