const std = @import("std");
const core = @import("unpolished-peas");
const effects = core.effects;
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

test "effects headless fallback applies a pixel effect to core canvas" {
    var canvas = try core.Canvas.init(std.testing.allocator, 1, 1);
    defer canvas.deinit();
    canvas.clear(core.Color.rgb(10, 20, 30));
    effects.applyPixelEffect(&canvas, try effects.PixelEffect.parse("invert", .{}));
    try std.testing.expectEqual(core.Color.rgb(245, 235, 225), canvas.get(0, 0).?);
}

test "effects shader reload reports validation failures without replacing active fallback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "effect.upshader", .data = "effect=invert\nuniform amount:f32\n" });
    var store = core.AssetStore.init(std.testing.allocator, tmp.dir);
    defer store.deinit();
    const handle = try store.loadShader("effect.upshader");
    const active = try (try effects.ShaderProgram.compile(try store.tryShaderSource(handle))).instantiate(.{});

    const stat = try tmp.dir.statFile("effect.upshader");
    std.Thread.sleep(1_100_000_000);
    try tmp.dir.writeFile(.{ .sub_path = "effect.upshader", .data = "effect=blur\n" });
    try std.testing.expect((try tmp.dir.statFile("effect.upshader")).mtime != stat.mtime);
    const events = try store.reloadChanged();
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqual(core.ReloadStatus.changed, events[0].status);
    try std.testing.expectError(error.InvalidShaderSource, effects.ShaderProgram.compile(try store.latestShaderSource(handle)));
    try std.testing.expectError(error.InvalidShaderReflection, effects.ShaderProgram.compile("effect=invert"));
    try std.testing.expectError(error.InvalidShaderParameter, (try effects.ShaderProgram.compile("effect=invert\nuniform amount:f32\n")).instantiate(.{ .amount = 2 }));
    try std.testing.expectEqual(core.Color.black, active.apply(core.Color.white));
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
    var command_canvas = try core.Canvas.init(std.testing.allocator, 4, 1);
    defer command_canvas.deinit();
    command_canvas.clear(core.Color.black);
    var renderer = core.HeadlessRenderer.init(std.testing.allocator, &command_canvas);
    defer renderer.deinit();
    try renderer.submit(commands.commands.items);
    try std.testing.expectEqualSlices(core.Color, canvas.pixels, command_canvas.pixels);
}
