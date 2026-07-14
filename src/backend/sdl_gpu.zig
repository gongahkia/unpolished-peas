const std = @import("std");
const builtin = @import("builtin");
const up = @import("unpolished-peas");
const sprite_shaders = @import("sprite-shaders");
const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

const sprite_vert_spirv = sprite_shaders.vert_spirv;
const sprite_frag_spirv = sprite_shaders.frag_spirv;
const sprite_vert_msl = sprite_shaders.vert_msl;
const sprite_frag_msl = sprite_shaders.frag_msl;
const primitive_vert_spirv = sprite_shaders.primitive_vert_spirv;
const primitive_frag_spirv = sprite_shaders.primitive_frag_spirv;
const primitive_vert_msl = sprite_shaders.primitive_vert_msl;
const primitive_frag_msl = sprite_shaders.primitive_frag_msl;
const effect_vert_spirv = sprite_shaders.effect_vert_spirv;
const effect_frag_spirv = sprite_shaders.effect_frag_spirv;
const effect_vert_msl = sprite_shaders.effect_vert_msl;
const effect_frag_msl = sprite_shaders.effect_frag_msl;

pub const GpuShaderFormat = enum {
    msl,
    spirv,
};

pub const GpuCapabilities = struct {
    pub const msl: u32 = @intCast(c.SDL_GPU_SHADERFORMAT_MSL);
    pub const spirv: u32 = @intCast(c.SDL_GPU_SHADERFORMAT_SPIRV);
    pub const required_shader_formats = msl | spirv;

    shader_formats: u32,

    pub fn preferredShaderFormat(self: GpuCapabilities) ?GpuShaderFormat {
        if ((self.shader_formats & msl) != 0) return .msl;
        if ((self.shader_formats & spirv) != 0) return .spirv;
        return null;
    }

    pub fn requireShaderFormat(self: GpuCapabilities) error{UnsupportedGpuShaderFormat}!GpuShaderFormat {
        return self.preferredShaderFormat() orelse error.UnsupportedGpuShaderFormat;
    }
};

test "SDL3 headers are available" {
    _ = c.SDL_INIT_VIDEO;
}

test "renderer conformance shared smoke golden fixture" {
    var canvas = try renderConformanceCanvas(std.testing.allocator, 4, 3);
    defer canvas.deinit();
    try expectConformanceGolden(&canvas);
}

test "renderer conformance reports unsupported shader capabilities" {
    try std.testing.expectEqual(GpuShaderFormat.msl, try (GpuCapabilities{ .shader_formats = GpuCapabilities.msl | GpuCapabilities.spirv }).requireShaderFormat());
    try std.testing.expectEqual(GpuShaderFormat.spirv, try (GpuCapabilities{ .shader_formats = GpuCapabilities.spirv }).requireShaderFormat());
    try std.testing.expectError(error.UnsupportedGpuShaderFormat, (GpuCapabilities{ .shader_formats = @intCast(c.SDL_GPU_SHADERFORMAT_DXIL) }).requireShaderFormat());
}

test "renderer conformance diagnostics name the backend and formats" {
    var buffer: [256]u8 = undefined;
    const diagnostic = try formatGpuDiagnostics(&buffer, "SDL_CreateGPUTexture", "vulkan", .{ .shader_formats = GpuCapabilities.spirv });
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "operation=SDL_CreateGPUTexture") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "driver=vulkan") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "shader_formats=0x2") != null);
}

test "SDL adapter consumes render commands" {
    var canvas = try up.Canvas.init(std.testing.allocator, 2, 2);
    defer canvas.deinit();
    var commands = up.RenderCommandBuffer.init(std.testing.allocator);
    defer commands.deinit();
    try commands.append(.{ .clear = up.Color.black });
    try commands.append(.{ .rect = .{ .x = 0, .y = 0, .w = 1, .h = 1, .color = up.Color.white } });

    try renderCommands(std.testing.allocator, &canvas, commands.commands.items);
    try std.testing.expectEqual(up.Color.white, canvas.get(0, 0).?);
}

test "swapchain lifecycle accepts minimized and resized frames" {
    var presentation = up.Presentation.init(.{ .x = 80, .y = 60 }, .{ .x = 80, .y = 60 }, .integer_fit);
    try std.testing.expect(!swapchainAvailable(null));
    updateFramebufferSize(&presentation, 640, 480);
    try std.testing.expectEqual(@as(f32, 640), presentation.framebuffer_size.x);
    try std.testing.expectEqual(@as(f32, 480), presentation.framebuffer_size.y);
}

test "GPU target readback preserves RGBA dimensions and pixels" {
    var canvas = try canvasFromRgba(std.testing.allocator, 2, 1, &.{ 1, 2, 3, 4, 5, 6, 7, 8 });
    defer canvas.deinit();
    try std.testing.expectEqual(@as(u32, 2), canvas.width);
    try std.testing.expectEqual(@as(u32, 1), canvas.height);
    try std.testing.expectEqual(up.Color.rgba(1, 2, 3, 4), canvas.pixels[0]);
    try std.testing.expectEqual(up.Color.rgba(5, 6, 7, 8), canvas.pixels[1]);
}

test "desktop renderer conformance GPU golden capture" {
    if (!rendererConformanceEnabled()) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const temp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(temp_path);
    const capture_path = try std.fs.path.join(std.testing.allocator, &.{ temp_path, "capture.png" });
    defer std.testing.allocator.free(capture_path);

    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return sdlRendererFail("SDL_Init");
    defer c.SDL_Quit();
    if (!c.SDL_GPUSupportsShaderFormats(requiredGpuShaderFormats(), null)) {
        printRendererConformanceUnavailable();
        if (rendererConformanceRequiresGpu()) return error.UnsupportedGpuShaderFormat;
        return;
    }
    const window = c.SDL_CreateWindow("unpolished-peas capture", 64, 32, c.SDL_WINDOW_HIDDEN) orelse return sdlRendererFail("SDL_CreateWindow");
    defer c.SDL_DestroyWindow(window);
    const device = c.SDL_CreateGPUDevice(requiredGpuShaderFormats(), false, null) orelse return sdlRendererFail("SDL_CreateGPUDevice");
    defer c.SDL_DestroyGPUDevice(device);
    const shader_format = try selectGpuShaderFormat(device);
    if (!c.SDL_ClaimWindowForGPUDevice(device, window)) return sdlGpuFail(device, "SDL_ClaimWindowForGPUDevice");
    defer c.SDL_ReleaseWindowFromGPUDevice(device, window);
    if (!c.SDL_SetGPUSwapchainParameters(device, window, c.SDL_GPU_SWAPCHAINCOMPOSITION_SDR, c.SDL_GPU_PRESENTMODE_VSYNC)) return sdlGpuFail(device, "SDL_SetGPUSwapchainParameters");

    var presenter = try Presenter.init(device, 64, 32);
    defer presenter.deinit(device);
    var canvas = try renderConformanceCanvas(std.testing.allocator, 64, 32);
    defer canvas.deinit();
    try expectConformanceGolden(&canvas);
    var assets = up.AssetStore.init(std.testing.allocator, std.fs.cwd());
    defer assets.deinit();
    const truetype = try assets.loadFont("examples/assets/fonts/Basic-Regular.ttf");
    const opentype = try assets.loadFont("examples/assets/fonts/SourceSans3-Regular.otf");
    const bitmap = try assets.loadBitmapFont("examples/assets/fonts/bitmap.fnt");
    var sprites = up.SpriteBatch.init(std.testing.allocator);
    defer sprites.deinit();
    try appendFontText(&sprites, 64, 32, try assets.tryFontPtr(truetype), "HÉ", 2, 2, up.Color.rgb(255, 198, 74));
    try appendFontText(&sprites, 64, 32, try assets.tryFontPtr(opentype), "HÉ", 22, 2, up.Color.rgb(122, 213, 255));
    try appendFontText(&sprites, 64, 32, try assets.tryFontPtr(bitmap), "B", 40, 2, up.Color.white);
    var commands = up.RenderCommandBuffer.init(std.testing.allocator);
    defer commands.deinit();
    var presentation = up.Presentation.init(.{ .x = 64, .y = 32 }, .{ .x = 64, .y = 32 }, .integer_fit);
    const effects = [_]up.PixelEffect{
        try up.PixelEffect.parse("invert", .{ .amount = 1 }),
        try up.PixelEffect.parse("invert", .{ .amount = 1 }),
    };
    var metrics = up.RuntimeMetrics{};
    metrics.beginFrame(0);
    try presenter.present(device, window, canvas, &sprites, commands.commands.items, &effects, capture_path, &presentation, &metrics);
    try std.testing.expect(metrics.gpu_frame_ns == null);
    try std.testing.expect(metrics.pass_count >= 4);
    try std.testing.expect(metrics.texture_bytes > 0);

    const png = try std.fs.cwd().readFileAlloc(std.testing.allocator, capture_path, 1024 * 1024);
    defer std.testing.allocator.free(png);
    var image = try up.Image.decode(std.testing.allocator, png, .{});
    defer image.deinit();
    try std.testing.expectEqual(@as(u32, 64), image.width);
    try std.testing.expectEqual(@as(u32, 32), image.height);
    const captured = up.Canvas{ .allocator = std.testing.allocator, .width = image.width, .height = image.height, .pixels = image.pixels };
    try expectConformanceGolden(&captured);
    var nontransparent: usize = 0;
    for (image.pixels) |pixel| {
        if (pixel.a != 0) nontransparent += 1;
    }
    try std.testing.expect(nontransparent > 2);
    std.debug.print("renderer conformance: platform={s} driver={s} shader_format={s} golden=capture.png\n", .{ @tagName(builtin.os.tag), gpuDriverName(device), @tagName(shader_format) });
}

test "high DPI letterboxing maps pointer through the GPU presentation" {
    const presentation = up.Presentation.init(.{ .x = 100, .y = 100 }, .{ .x = 400, .y = 200 }, .fit);
    const center = pointerFramebufferPoint(.{ .x = 100, .y = 50 }, .{ .x = 200, .y = 100 }, &presentation);
    try std.testing.expectEqual(up.Vec2.init(200, 100), center);
    try std.testing.expectEqual(up.Vec2.init(50, 50), presentation.framebufferToCanvas(center).?);
    const letterbox = pointerFramebufferPoint(.{ .x = 0, .y = 50 }, .{ .x = 200, .y = 100 }, &presentation);
    try std.testing.expect(presentation.framebufferToCanvas(letterbox) == null);
}

test "sprite residency detects a reloaded image buffer" {
    var first = [_]up.Color{up.Color.white};
    var second = [_]up.Color{up.Color.black};
    var image = up.Image{ .allocator = std.testing.allocator, .width = 1, .height = 1, .pixels = first[0..] };
    const resident = Presenter.SpriteTexture{
        .image = &image,
        .texture = undefined,
        .transfer = undefined,
        .pixels = image.pixels.ptr,
        .width = image.width,
        .height = image.height,
    };
    try std.testing.expect(resident.matches(&image));
    image.pixels = second[0..];
    try std.testing.expect(!resident.matches(&image));
}

test "GPU atlas quads preserve center origin, flip, rotation, tint, and filtering" {
    var pixels = [_]up.Color{up.Color.white} ** 8;
    var image_path = [_]u8{'x'};
    var frame_name = [_]u8{'f'};
    var frames = [_]up.AtlasFrame{.{
        .name = frame_name[0..],
        .x = 1,
        .y = 0,
        .w = 2,
        .h = 1,
        .source_w = 2,
        .source_h = 1,
        .offset_x = 0,
        .offset_y = 0,
    }};
    const animations = [_]up.Animation{};
    const atlas = up.Atlas{
        .allocator = std.testing.allocator,
        .image = .{ .allocator = std.testing.allocator, .width = 4, .height = 2, .pixels = pixels[0..] },
        .image_path = image_path[0..],
        .frames = frames[0..],
        .animations = animations[0..],
    };
    var batch = up.SpriteBatch.init(std.testing.allocator);
    defer batch.deinit();
    try appendAtlasQuad(&batch, 100, 100, &atlas, .{ .index = 0 }, 50, 40, .{ .origin = .center, .scale = 2, .flip_x = true, .tint = up.Color.rgb(255, 128, 0), .rotation = 1.5707964, .sampling = .linear });
    try std.testing.expectEqual(@as(usize, 1), batch.draws.items.len);
    try std.testing.expectEqual(up.SpriteSampling.linear, batch.draws.items[0].sampling);
    try std.testing.expectApproxEqAbs(@as(f32, 0.02), batch.vertices.items[0].x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.16), batch.vertices.items[0].y, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), batch.vertices.items[0].g, 0.0001);
    batch.clear();
    for ([_]bool{ false, true }) |center| for ([_]bool{ false, true }) |flip_x| for ([_]bool{ false, true }) |flip_y| {
        try appendAtlasQuad(&batch, 100, 100, &atlas, .{ .index = 0 }, 50, 40, .{ .origin = if (center) .center else .top_left, .scale = 2, .flip_x = flip_x, .flip_y = flip_y, .tint = up.Color.rgb(255, 128, 0), .rotation = if (flip_x or flip_y) 0.25 else 0, .sampling = if (center) .linear else .nearest });
    };
    try std.testing.expectEqual(@as(usize, 8), batch.draws.items.len);
    try std.testing.expectEqual(@as(usize, 48), batch.vertices.items.len);
}

test "font assets build GPU sprite quads" {
    var assets = up.AssetStore.init(std.testing.allocator, std.fs.cwd());
    defer assets.deinit();
    const truetype = try assets.loadFont("examples/assets/fonts/Basic-Regular.ttf");
    const opentype = try assets.loadFont("examples/assets/fonts/SourceSans3-Regular.otf");
    const bitmap = try assets.loadBitmapFont("examples/assets/fonts/bitmap.fnt");
    const ttf = try assets.tryFontPtr(truetype);
    const otf = try assets.tryFontPtr(opentype);
    const bmfont = try assets.tryFontPtr(bitmap);
    var batch = up.SpriteBatch.init(std.testing.allocator);
    defer batch.deinit();
    try appendFontText(&batch, 160, 90, ttf, "HÉ", 4, 8, up.Color.rgb(255, 198, 74));
    try appendFontText(&batch, 160, 90, otf, "HÉ", 4, 32, up.Color.rgb(122, 213, 255));
    try appendFontText(&batch, 160, 90, bmfont, "B?", 4, 56, up.Color.white);
    try std.testing.expectEqual(@as(usize, 6), batch.draws.items.len);
    try std.testing.expect(batch.draws.items[0].image == &ttf.image);
    try std.testing.expectEqual(up.SpriteSampling.linear, batch.draws.items[0].sampling);
    try std.testing.expect(batch.draws.items[2].image == &otf.image);
    try std.testing.expectEqual(up.SpriteSampling.linear, batch.draws.items[2].sampling);
    try std.testing.expect(batch.draws.items[4].image == &bmfont.image);
    try std.testing.expectEqual(up.SpriteSampling.nearest, batch.draws.items[4].sampling);
    try std.testing.expectEqual(@as(usize, 36), batch.vertices.items.len);
}

test "headless and GPU font paths use identical Unicode fallback glyphs" {
    var pixels = [_]up.Color{ up.Color.white, up.Color.rgb(255, 0, 0) };
    var glyphs = [_]up.FontGlyph{
        .{ .codepoint = 'A', .x = 0, .y = 0, .width = 1, .height = 1, .x_offset = 0, .y_offset = 0, .advance = 2 },
        .{ .codepoint = '?', .x = 1, .y = 0, .width = 1, .height = 1, .x_offset = 0, .y_offset = 0, .advance = 2 },
    };
    const font = up.Font{
        .allocator = std.testing.allocator,
        .image = .{ .allocator = std.testing.allocator, .width = 2, .height = 1, .pixels = &pixels },
        .glyphs = &glyphs,
        .line_height = 2,
        .baseline = 0,
        .sampling = .nearest,
    };
    const text = [_]u8{ 'A', 0xe4, 0xb8, 0x80 };
    var canvas = try up.Canvas.init(std.testing.allocator, 6, 2);
    defer canvas.deinit();
    font.drawText(&canvas, &text, 0, 0, up.Color.white);

    var batch = up.SpriteBatch.init(std.testing.allocator);
    defer batch.deinit();
    try appendFontText(&batch, 6, 2, &font, &text, 0, 0, up.Color.white);
    try std.testing.expectEqual(up.Color.white, canvas.get(0, 0).?);
    try std.testing.expectEqual(up.Color.rgb(255, 0, 0), canvas.get(2, 0).?);
    try std.testing.expectEqual(@as(usize, 2), batch.draws.items.len);
    try std.testing.expectEqual(@as(u32, 0), batch.draws.items[0].source.x);
    try std.testing.expectEqual(@as(u32, 1), batch.draws.items[1].source.x);
}

test "primitive commands build GPU vertices without CPU canvas access" {
    var commands = up.RenderCommandBuffer.init(std.testing.allocator);
    defer commands.deinit();
    try commands.append(.{ .rect = .{ .x = 1, .y = 1, .w = 4, .h = 3, .color = up.Color.white } });
    try commands.append(.{ .stroke_rect = .{ .x = 7, .y = 1, .w = 4, .h = 3, .color = up.Color.white } });
    try commands.append(.{ .circle = .{ .x = 4, .y = 9, .radius = 3, .color = up.Color.white } });
    try commands.append(.{ .stroke_circle = .{ .x = 11, .y = 9, .radius = 3, .color = up.Color.white } });
    try commands.append(.{ .line = .{ .x0 = 1, .y0 = 14, .x1 = 6, .y1 = 14, .color = up.Color.white } });
    try commands.append(.{ .triangle = .{ .a = .{ .x = 8, .y = 12 }, .b = .{ .x = 12, .y = 12 }, .c = .{ .x = 10, .y = 15 }, .color = up.Color.white } });
    try commands.append(.{ .stroke_triangle = .{ .a = .{ .x = 1, .y = 20 }, .b = .{ .x = 5, .y = 20 }, .c = .{ .x = 3, .y = 23 }, .color = up.Color.white } });
    try commands.append(.{ .text = .{ .value = "A", .x = 8, .y = 18, .color = up.Color.white } });
    var batch = up.PrimitiveBatch.init(std.testing.allocator);
    defer batch.deinit();
    try appendPrimitiveCommands(&batch, 32, 32, commands.commands.items);
    try std.testing.expect(batch.vertices.items.len > 100);
}

test "GPU primitive draws retain nested clip and blend state" {
    var commands = up.RenderCommandBuffer.init(std.testing.allocator);
    defer commands.deinit();
    try commands.append(.{ .push_clip = .{ .x = 1, .y = 1, .w = 8, .h = 8 } });
    try commands.append(.{ .rect = .{ .x = 0, .y = 0, .w = 16, .h = 16, .color = up.Color.white } });
    try commands.append(.{ .push_clip = .{ .x = 3, .y = 3, .w = 4, .h = 4 } });
    try commands.append(.{ .push_blend = .additive });
    try commands.append(.{ .rect = .{ .x = 0, .y = 0, .w = 16, .h = 16, .color = up.Color.white } });
    try commands.append(.pop_blend);
    try commands.append(.pop_clip);
    try commands.append(.{ .rect = .{ .x = 0, .y = 0, .w = 16, .h = 16, .color = up.Color.white } });
    try commands.append(.pop_clip);
    try commands.append(.{ .rect = .{ .x = 0, .y = 0, .w = 16, .h = 16, .color = up.Color.white } });
    var batch = up.PrimitiveBatch.init(std.testing.allocator);
    defer batch.deinit();
    try appendPrimitiveCommands(&batch, 16, 16, commands.commands.items);
    try std.testing.expectEqual(@as(usize, 4), batch.draws.items.len);
    try std.testing.expectEqual(up.BlendMode.alpha, batch.draws.items[0].blend);
    try std.testing.expectEqual(up.ClipRect{ .x = 3, .y = 3, .w = 4, .h = 4 }, batch.draws.items[1].clip.?);
    try std.testing.expectEqual(up.BlendMode.additive, batch.draws.items[1].blend);
    try std.testing.expectEqual(up.ClipRect{ .x = 1, .y = 1, .w = 8, .h = 8 }, batch.draws.items[2].clip.?);
    try std.testing.expect(batch.draws.items[3].clip == null);
    try std.testing.expectEqual(up.BlendMode.alpha, batch.draws.items[3].blend);
}

test "audio device removal and format changes request recovery" {
    try std.testing.expect(audioDeviceChanged(c.SDL_EVENT_AUDIO_DEVICE_REMOVED));
    try std.testing.expect(audioDeviceChanged(c.SDL_EVENT_AUDIO_DEVICE_FORMAT_CHANGED));
    try std.testing.expect(!audioDeviceChanged(c.SDL_EVENT_QUIT));
}

pub fn renderCommands(allocator: std.mem.Allocator, canvas: *up.Canvas, commands: []const up.RenderCommand) !void {
    var renderer = up.HeadlessRenderer.init(canvas);
    defer renderer.deinit(allocator);
    try renderer.submit(allocator, commands);
}

pub const Config = struct {
    title: [:0]const u8 = "unpolished-peas",
    organization: [:0]const u8 = "gongahkia",
    application: [:0]const u8 = "unpolished-peas",
    width: u32 = 320,
    height: u32 = 180,
    scale: u32 = 3,
    resizable: bool = false,
    presentation_mode: up.PresentationMode = .integer_fit,
    fixed_hz: u32 = 60,
    audio_sample_rate: u32 = 48_000,
    audio_buffer_frames: u32 = 1024,
    strict_audio: bool = false,
    asset_root: ?[]const u8 = null,
    actions: []const up.Action = &.{},
    developer_tools: bool = builtin.mode == .Debug,
    cpu_profiler: bool = builtin.mode == .Debug,
    pause_policy: PausePolicy = .never,
    clear_color: up.Color = up.Color.black,
    max_frames: ?u32 = null,
};

pub const PausePolicy = enum {
    never,
    unfocused,
    minimized,
};

pub const Event = union(enum) {
    close_requested,
    focus_gained,
    focus_lost,
    minimized,
    restored,
    resized: struct { framebuffer_size: up.Vec2 },
    gamepad_connected: i32,
    gamepad_disconnected: i32,
    audio_device_changed,
    gpu_device_reset,
    gpu_device_lost,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    canvas: *up.Canvas,
    input: *up.Input,
    actions: *up.ActionMap,
    assets: *up.AssetStore,
    audio: *up.AudioMixer,
    app_data_path: []const u8,
    presentation: *const up.Presentation,
    sprite_batch: *up.SpriteBatch,
    commands: *up.RenderCommandBuffer,
    pixel_effects: *up.PostProcessChain,
    inspector: *up.Inspector,
    profiler: *up.FrameProfiler,
    runtime_metrics: *up.RuntimeMetrics,
    capture_requested: *bool,
    dt: f32,
    frame: u64,

    pub fn clear(self: *Context, color: up.Color) void {
        self.canvas.clear(color);
    }

    pub fn camera(self: *Context, target_camera: *const up.Camera2D) up.CameraCanvas {
        return .init(self.canvas, target_camera);
    }

    pub fn gpuCamera(self: *Context, target_camera: *const up.Camera2D) GpuCameraCanvas {
        return .init(self.commands, target_camera, .{ .x = @floatFromInt(self.canvas.width), .y = @floatFromInt(self.canvas.height) });
    }

    pub fn canvasToFramebuffer(self: *const Context, point: up.Vec2) ?up.Vec2 {
        return self.presentation.canvasToFramebuffer(point);
    }

    pub fn framebufferToCanvas(self: *const Context, point: up.Vec2) ?up.Vec2 {
        return self.presentation.framebufferToCanvas(point);
    }

    pub fn rect(self: *Context, x: i32, y: i32, w: i32, h: i32, color: up.Color) void {
        self.commands.append(.{ .rect = .{ .x = x, .y = y, .w = w, .h = h, .color = color } }) catch self.canvas.fillRect(x, y, w, h, color);
    }

    pub fn circle(self: *Context, x: i32, y: i32, radius: i32, color: up.Color) void {
        self.commands.append(.{ .circle = .{ .x = x, .y = y, .radius = radius, .color = color } }) catch self.canvas.fillCircle(x, y, radius, color);
    }

    pub fn line(self: *Context, x0: i32, y0: i32, x1: i32, y1: i32, color: up.Color) void {
        self.commands.append(.{ .line = .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1, .color = color } }) catch self.canvas.line(x0, y0, x1, y1, color);
    }

    pub fn text(self: *Context, value: []const u8, x: i32, y: i32, color: up.Color) void {
        self.commands.append(.{ .text = .{ .value = value, .x = x, .y = y, .color = color } }) catch self.canvas.drawText(value, x, y, color);
    }

    pub fn font(self: *Context, handle: up.FontHandle, value: []const u8, x: i32, y: i32, color: up.Color) void {
        const source_font = self.assets.latestFontPtr(handle) catch @panic("invalid font handle");
        appendFontText(self.sprite_batch, self.canvas.width, self.canvas.height, source_font, value, x, y, color) catch source_font.drawText(self.canvas, value, x, y, color);
    }

    pub fn strokeRect(self: *Context, x: i32, y: i32, w: i32, h: i32, color: up.Color) void {
        self.commands.append(.{ .stroke_rect = .{ .x = x, .y = y, .w = w, .h = h, .color = color } }) catch self.canvas.strokeRect(x, y, w, h, color);
    }

    pub fn strokeCircle(self: *Context, x: i32, y: i32, radius: i32, color: up.Color) void {
        self.commands.append(.{ .stroke_circle = .{ .x = x, .y = y, .radius = radius, .color = color } }) catch self.canvas.fillCircle(x, y, radius, color);
    }

    pub fn triangle(self: *Context, a: up.Vec2, b: up.Vec2, c_point: up.Vec2, color: up.Color) void {
        self.commands.append(.{ .triangle = .{ .a = a, .b = b, .c = c_point, .color = color } }) catch self.canvas.fillTriangle(a, b, c_point, color);
    }

    pub fn strokeTriangle(self: *Context, a: up.Vec2, b: up.Vec2, c_point: up.Vec2, color: up.Color) void {
        self.commands.append(.{ .stroke_triangle = .{ .a = a, .b = b, .c = c_point, .color = color } }) catch {
            self.canvas.line(@intFromFloat(@round(a.x)), @intFromFloat(@round(a.y)), @intFromFloat(@round(b.x)), @intFromFloat(@round(b.y)), color);
            self.canvas.line(@intFromFloat(@round(b.x)), @intFromFloat(@round(b.y)), @intFromFloat(@round(c_point.x)), @intFromFloat(@round(c_point.y)), color);
            self.canvas.line(@intFromFloat(@round(c_point.x)), @intFromFloat(@round(c_point.y)), @intFromFloat(@round(a.x)), @intFromFloat(@round(a.y)), color);
        };
    }

    pub fn pushClip(self: *Context, clip_rect: up.ClipRect) void {
        self.commands.append(.{ .push_clip = clip_rect }) catch @panic("render command allocation failed");
    }

    pub fn popClip(self: *Context) void {
        self.commands.append(.pop_clip) catch @panic("render command allocation failed");
    }

    pub fn pushBlend(self: *Context, blend: up.BlendMode) void {
        self.commands.append(.{ .push_blend = blend }) catch @panic("render command allocation failed");
    }

    pub fn popBlend(self: *Context) void {
        self.commands.append(.pop_blend) catch @panic("render command allocation failed");
    }

    pub fn setPixelEffect(self: *Context, source: []const u8, params: up.PixelEffectParameters) !void {
        self.pixel_effects.replace(try up.PixelEffect.parse(source, params));
    }

    pub fn clearPixelEffect(self: *Context) void {
        self.pixel_effects.clear();
    }

    pub fn registerInspectorPanel(self: *Context, panel: up.InspectorPanel) !void {
        try self.inspector.register(panel);
    }

    pub fn toggleInspector(self: *Context) void {
        self.inspector.toggle();
    }

    pub fn profile(self: *Context, scope: up.ProfileScope) up.ProfileTimer {
        return self.profiler.scope(scope);
    }

    pub fn profileMetrics(self: *const Context) up.ProfileMetrics {
        return self.profiler.metrics();
    }

    pub fn runtimeMetrics(self: *const Context) up.RuntimeMetrics {
        return self.runtime_metrics.*;
    }

    pub fn exportCpuTrace(self: *const Context) !void {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "{s}cpu-trace.json", .{self.app_data_path});
        try self.profiler.writeTrace(path);
    }

    pub fn loadShader(self: *Context, path: []const u8) !up.ShaderAssetHandle {
        const timer = self.profile(.asset);
        defer timer.end();
        return self.assets.loadShader(path);
    }

    pub fn setShaderEffect(self: *Context, handle: up.ShaderAssetHandle, params: up.PixelEffectParameters) !void {
        self.pixel_effects.replace(try (try self.assets.latestShader(handle)).instantiate(params));
    }

    pub fn appendPixelEffect(self: *Context, source: []const u8, params: up.PixelEffectParameters) !void {
        try self.pixel_effects.append(try up.PixelEffect.parse(source, params));
    }

    pub fn captureFrame(self: *Context) void {
        self.capture_requested.* = true;
    }

    pub fn image(self: *Context, handle: up.ImageHandle, x: i32, y: i32) void {
        const source_image = self.assets.latestImagePtr(handle) catch @panic("invalid image handle");
        appendImageQuad(self.sprite_batch, self.canvas.width, self.canvas.height, source_image, x, y) catch self.canvas.drawImage(source_image.*, x, y);
    }

    pub fn sprite(self: *Context, atlas_handle: up.AtlasHandle, frame: up.AtlasFrameHandle, x: i32, y: i32, options: up.DrawSpriteOptions) void {
        const source_atlas = self.assets.latestAtlasPtr(atlas_handle) catch @panic("invalid atlas handle");
        appendAtlasQuad(self.sprite_batch, self.canvas.width, self.canvas.height, source_atlas, frame, x, y, options) catch self.canvas.drawAtlasFrame(source_atlas.*, frame, x, y, options);
    }

    pub fn loadPng(self: *Context, path: []const u8) !up.ImageHandle {
        const timer = self.profile(.asset);
        defer timer.end();
        return self.assets.loadPng(path);
    }

    pub fn loadImage(self: *Context, path: []const u8) !up.ImageHandle {
        const timer = self.profile(.asset);
        defer timer.end();
        return self.assets.loadImage(path);
    }

    pub fn loadAtlas(self: *Context, path: []const u8) !up.AtlasHandle {
        const timer = self.profile(.asset);
        defer timer.end();
        return self.assets.loadAtlas(path);
    }

    pub fn loadFont(self: *Context, path: []const u8) !up.FontHandle {
        const timer = self.profile(.asset);
        defer timer.end();
        return self.assets.loadFont(path);
    }

    pub fn loadFontWithOptions(self: *Context, path: []const u8, options: up.FontLoadOptions) !up.FontHandle {
        const timer = self.profile(.asset);
        defer timer.end();
        return self.assets.loadFontWithOptions(path, options);
    }

    pub fn loadBitmapFont(self: *Context, path: []const u8) !up.FontHandle {
        const timer = self.profile(.asset);
        defer timer.end();
        return self.assets.loadBitmapFont(path);
    }

    pub fn fontAsset(self: *Context, handle: up.FontHandle) *const up.Font {
        return self.assets.latestFontPtr(handle) catch @panic("invalid font handle");
    }

    pub fn atlasFrame(self: *Context, atlas_handle: up.AtlasHandle, name: []const u8) ?up.AtlasFrameHandle {
        return self.assets.atlas(atlas_handle).findFrame(name);
    }

    pub fn atlas(self: *Context, atlas_handle: up.AtlasHandle) *const up.Atlas {
        return self.assets.latestAtlasPtr(atlas_handle) catch @panic("invalid atlas handle");
    }

    pub fn atlasAnimation(self: *Context, atlas_handle: up.AtlasHandle, name: []const u8) ?up.AnimationHandle {
        return self.assets.atlas(atlas_handle).findAnimation(name);
    }

    pub fn loadTileMap(self: *Context, path: []const u8) !up.TileMapHandle {
        const timer = self.profile(.asset);
        defer timer.end();
        return self.assets.loadTileMap(path);
    }

    pub fn loadTileMapWithOptions(self: *Context, path: []const u8, options: up.TileMapAssetOptions) !up.TileMapHandle {
        const timer = self.profile(.asset);
        defer timer.end();
        return self.assets.loadTileMapWithOptions(path, options);
    }

    pub fn tileMap(self: *Context, handle: up.TileMapHandle) *const up.TileMap {
        return self.assets.tileMapPtr(handle);
    }

    pub fn drawTileMap(self: *Context, handle: up.TileMapHandle, target_camera: *const up.Camera2D, time: f32) void {
        self.assets.drawTileMap(handle, target_camera, self.canvas, time);
    }

    pub fn loadText(self: *Context, path: []const u8) !up.TextHandle {
        const timer = self.profile(.asset);
        defer timer.end();
        return self.assets.loadText(path);
    }

    pub fn textAsset(self: *Context, handle: up.TextHandle) []const u8 {
        return self.assets.latestText(handle) catch @panic("invalid text handle");
    }

    pub fn down(self: *Context, key: up.Key) bool {
        return self.input.isDown(key);
    }

    pub fn actionValue(self: *Context, context: []const u8, name: []const u8) f32 {
        return self.actions.value(self.input.*, context, name);
    }

    pub fn actionIsDown(self: *Context, context: []const u8, name: []const u8) bool {
        return self.actions.isDown(context, name);
    }

    pub fn actionWasPressed(self: *Context, context: []const u8, name: []const u8) bool {
        return self.actions.wasPressed(context, name);
    }

    pub fn actionWasReleased(self: *Context, context: []const u8, name: []const u8) bool {
        return self.actions.wasReleased(context, name);
    }

    pub fn rebindAction(self: *Context, context: []const u8, name: []const u8, binding: up.ActionBinding) !void {
        try self.actions.rebind(context, name, binding);
    }

    pub fn rebindActionBinding(self: *Context, context: []const u8, name: []const u8, binding_index: usize, binding: up.ActionBinding) !void {
        try self.actions.rebindBinding(context, name, binding_index, binding);
    }

    pub fn appDataPath(self: *Context) []const u8 {
        return self.app_data_path;
    }

    pub fn rumbleGamepad(_: *Context, id: i32, low: f32, high: f32, duration_ms: u32) bool {
        if (low < 0 or low > 1 or high < 0 or high > 1) return false;
        const gamepad = c.SDL_OpenGamepad(@intCast(id)) orelse return false;
        defer c.SDL_CloseGamepad(gamepad);
        return c.SDL_RumbleGamepad(gamepad, @intFromFloat(low * 65535), @intFromFloat(high * 65535), duration_ms);
    }

    pub fn assetPath(self: *Context, path: []const u8) ![]u8 {
        return self.assets.assetPath(self.allocator, path);
    }
};

pub const GpuCameraCanvas = struct {
    commands: *up.RenderCommandBuffer,
    camera: *const up.Camera2D,
    canvas_size: up.Vec2,

    pub fn init(commands: *up.RenderCommandBuffer, camera: *const up.Camera2D, canvas_size: up.Vec2) GpuCameraCanvas {
        return .{ .commands = commands, .camera = camera, .canvas_size = canvas_size };
    }

    pub fn line(self: GpuCameraCanvas, from: up.Vec2, to: up.Vec2, color: up.Color) void {
        const a = self.camera.worldToCanvas(from, self.canvas_size);
        const b = self.camera.worldToCanvas(to, self.canvas_size);
        self.withViewport(.{ .line = .{ .x0 = @intFromFloat(@round(a.x)), .y0 = @intFromFloat(@round(a.y)), .x1 = @intFromFloat(@round(b.x)), .y1 = @intFromFloat(@round(b.y)), .color = color } });
    }

    pub fn fillRect(self: GpuCameraCanvas, rect: up.Rect, color: up.Color) void {
        if (!self.camera.isVisibleRect(rect, self.canvas_size)) return;
        const a = self.camera.worldToCanvas(.{ .x = rect.x, .y = rect.y }, self.canvas_size);
        const b = self.camera.worldToCanvas(.{ .x = rect.x + rect.w, .y = rect.y }, self.canvas_size);
        const c_point = self.camera.worldToCanvas(.{ .x = rect.x + rect.w, .y = rect.y + rect.h }, self.canvas_size);
        const d = self.camera.worldToCanvas(.{ .x = rect.x, .y = rect.y + rect.h }, self.canvas_size);
        self.pushViewport();
        self.append(.{ .triangle = .{ .a = a, .b = b, .c = c_point, .color = color } });
        self.append(.{ .triangle = .{ .a = a, .b = c_point, .c = d, .color = color } });
        self.append(.pop_clip);
    }

    pub fn fillCircle(self: GpuCameraCanvas, center: up.Vec2, radius: f32, color: up.Color) void {
        if (!self.camera.isVisibleRect(.init(center.x - radius, center.y - radius, radius * 2, radius * 2), self.canvas_size)) return;
        const screen = self.camera.worldToCanvas(center, self.canvas_size);
        self.withViewport(.{ .circle = .{ .x = @intFromFloat(@round(screen.x)), .y = @intFromFloat(@round(screen.y)), .radius = @max(@as(i32, 1), @as(i32, @intFromFloat(@round(radius * self.camera.zoom)))), .color = color } });
    }

    pub fn strokeRect(self: GpuCameraCanvas, rect: up.Rect, color: up.Color) void {
        self.line(.{ .x = rect.x, .y = rect.y }, .{ .x = rect.x + rect.w, .y = rect.y }, color);
        self.line(.{ .x = rect.x + rect.w, .y = rect.y }, .{ .x = rect.x + rect.w, .y = rect.y + rect.h }, color);
        self.line(.{ .x = rect.x + rect.w, .y = rect.y + rect.h }, .{ .x = rect.x, .y = rect.y + rect.h }, color);
        self.line(.{ .x = rect.x, .y = rect.y + rect.h }, .{ .x = rect.x, .y = rect.y }, color);
    }

    fn withViewport(self: GpuCameraCanvas, command: up.RenderCommand) void {
        self.pushViewport();
        self.append(command);
        self.append(.pop_clip);
    }

    fn pushViewport(self: GpuCameraCanvas) void {
        const viewport = self.camera.canvasViewport(self.canvas_size);
        self.append(.{ .push_clip = .{ .x = @intFromFloat(@floor(viewport.x)), .y = @intFromFloat(@floor(viewport.y)), .w = @max(@as(i32, 0), @as(i32, @intFromFloat(@ceil(viewport.w)))), .h = @max(@as(i32, 0), @as(i32, @intFromFloat(@ceil(viewport.h)))) } });
    }

    fn append(self: GpuCameraCanvas, command: up.RenderCommand) void {
        self.commands.append(command) catch @panic("render command allocation failed");
    }
};

fn appendImageQuad(batch: *up.SpriteBatch, canvas_width: u32, canvas_height: u32, image: *const up.Image, x: i32, y: i32) !void {
    const width: f32 = @floatFromInt(image.width);
    const height: f32 = @floatFromInt(image.height);
    const left: f32 = @floatFromInt(x);
    const top: f32 = @floatFromInt(y);
    const positions = .{
        clipPoint(canvas_width, canvas_height, left, top),
        clipPoint(canvas_width, canvas_height, left + width, top),
        clipPoint(canvas_width, canvas_height, left + width, top + height),
        clipPoint(canvas_width, canvas_height, left, top + height),
    };
    try batch.appendQuad(image, .{ .x = 0, .y = 0, .w = image.width, .h = image.height }, positions, .{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 1, .y = 1 }, .{ .x = 0, .y = 1 } }, up.Color.white, .nearest);
}

fn appendAtlasQuad(batch: *up.SpriteBatch, canvas_width: u32, canvas_height: u32, atlas: *const up.Atlas, handle: up.AtlasFrameHandle, x: i32, y: i32, options: up.DrawSpriteOptions) !void {
    if (options.scale == 0) return error.InvalidSpriteTransform;
    const frame = atlas.frame(handle);
    if (frame.x < 0 or frame.y < 0 or frame.w <= 0 or frame.h <= 0 or frame.source_w <= 0 or frame.source_h <= 0) return error.InvalidSourceRect;
    const scale: f32 = @floatFromInt(options.scale);
    const source_width: f32 = @floatFromInt(frame.source_w);
    const source_height: f32 = @floatFromInt(frame.source_h);
    const trim_width: f32 = @floatFromInt(if (frame.rotated) frame.h else frame.w);
    const trim_height: f32 = @floatFromInt(if (frame.rotated) frame.w else frame.h);
    var anchor_x: f32 = @floatFromInt(x);
    var anchor_y: f32 = @floatFromInt(y);
    if (options.origin == .center) {
        anchor_x -= source_width * scale / 2;
        anchor_y -= source_height * scale / 2;
    }
    const center = up.SpriteBatchPoint{ .x = anchor_x + source_width * scale / 2, .y = anchor_y + source_height * scale / 2 };
    const locals = [_]up.SpriteBatchPoint{ .{ .x = 0, .y = 0 }, .{ .x = trim_width, .y = 0 }, .{ .x = trim_width, .y = trim_height }, .{ .x = 0, .y = trim_height } };
    var positions: [4]up.SpriteBatchPoint = undefined;
    for (locals, 0..) |local, index| {
        var logical_x = @as(f32, @floatFromInt(frame.offset_x)) + local.x;
        var logical_y = @as(f32, @floatFromInt(frame.offset_y)) + local.y;
        if (options.flip_x) logical_x = source_width - logical_x;
        if (options.flip_y) logical_y = source_height - logical_y;
        const point = rotatePoint(.{ .x = anchor_x + logical_x * scale, .y = anchor_y + logical_y * scale }, center, options.rotation);
        positions[index] = clipPoint(canvas_width, canvas_height, point.x, point.y);
    }
    const image_width: f32 = @floatFromInt(atlas.image.width);
    const image_height: f32 = @floatFromInt(atlas.image.height);
    const uv_x0 = @as(f32, @floatFromInt(frame.x)) / image_width;
    const uv_y0 = @as(f32, @floatFromInt(frame.y)) / image_height;
    const uv_x1 = @as(f32, @floatFromInt(frame.x + frame.w)) / image_width;
    const uv_y1 = @as(f32, @floatFromInt(frame.y + frame.h)) / image_height;
    const uvs: [4]up.SpriteBatchUv = if (frame.rotated)
        .{ .{ .x = uv_x0, .y = uv_y1 }, .{ .x = uv_x0, .y = uv_y0 }, .{ .x = uv_x1, .y = uv_y0 }, .{ .x = uv_x1, .y = uv_y1 } }
    else
        .{ .{ .x = uv_x0, .y = uv_y0 }, .{ .x = uv_x1, .y = uv_y0 }, .{ .x = uv_x1, .y = uv_y1 }, .{ .x = uv_x0, .y = uv_y1 } };
    try batch.appendQuad(&atlas.image, .{ .x = @intCast(frame.x), .y = @intCast(frame.y), .w = @intCast(frame.w), .h = @intCast(frame.h) }, positions, uvs, options.tint, options.sampling);
}

fn appendFontText(batch: *up.SpriteBatch, canvas_width: u32, canvas_height: u32, font: *const up.Font, text: []const u8, x: i32, y: i32, color: up.Color) !void {
    var index: usize = 0;
    var pen_x = x;
    var pen_y = y;
    while (up.Font.nextCodepoint(text, &index)) |codepoint| {
        if (codepoint == '\r') continue;
        if (codepoint == '\n') {
            pen_x = x;
            pen_y = saturatingAdd(pen_y, font.line_height);
            continue;
        }
        const glyph = font.resolveGlyph(codepoint).glyph orelse continue;
        if (glyph.width != 0 and glyph.height != 0) {
            const left: f32 = @floatFromInt(saturatingAdd(pen_x, glyph.x_offset));
            const top: f32 = @floatFromInt(saturatingAdd(saturatingAdd(pen_y, font.baseline), glyph.y_offset));
            const right = left + @as(f32, @floatFromInt(glyph.width));
            const bottom = top + @as(f32, @floatFromInt(glyph.height));
            const image_width: f32 = @floatFromInt(font.image.width);
            const image_height: f32 = @floatFromInt(font.image.height);
            const uv_x0 = @as(f32, @floatFromInt(glyph.x)) / image_width;
            const uv_y0 = @as(f32, @floatFromInt(glyph.y)) / image_height;
            const uv_x1 = @as(f32, @floatFromInt(glyph.x + glyph.width)) / image_width;
            const uv_y1 = @as(f32, @floatFromInt(glyph.y + glyph.height)) / image_height;
            try batch.appendQuad(&font.image, .{ .x = glyph.x, .y = glyph.y, .w = glyph.width, .h = glyph.height }, .{ clipPoint(canvas_width, canvas_height, left, top), clipPoint(canvas_width, canvas_height, right, top), clipPoint(canvas_width, canvas_height, right, bottom), clipPoint(canvas_width, canvas_height, left, bottom) }, .{ .{ .x = uv_x0, .y = uv_y0 }, .{ .x = uv_x1, .y = uv_y0 }, .{ .x = uv_x1, .y = uv_y1 }, .{ .x = uv_x0, .y = uv_y1 } }, color, font.sampling);
        }
        pen_x = saturatingAdd(pen_x, glyph.advance);
    }
}

fn clipPoint(canvas_width: u32, canvas_height: u32, x: f32, y: f32) up.SpriteBatchPoint {
    return .{ .x = x * 2 / @as(f32, @floatFromInt(canvas_width)) - 1, .y = 1 - y * 2 / @as(f32, @floatFromInt(canvas_height)) };
}

fn rotatePoint(point: up.SpriteBatchPoint, center: up.SpriteBatchPoint, angle: f32) up.SpriteBatchPoint {
    const sin = @sin(angle);
    const cos = @cos(angle);
    const x = point.x - center.x;
    const y = point.y - center.y;
    return .{ .x = center.x + x * cos - y * sin, .y = center.y + x * sin + y * cos };
}

pub fn appDataPath(allocator: std.mem.Allocator, organization: [:0]const u8, application: [:0]const u8) ![]u8 {
    const raw = c.SDL_GetPrefPath(organization.ptr, application.ptr) orelse return sdlFail("SDL_GetPrefPath");
    defer c.SDL_free(raw);
    return allocator.dupe(u8, std.mem.span(raw));
}

pub fn play(config: Config, comptime Game: type) !void {
    comptime validateGame(Game);
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) @panic("game allocation leak");

    const allocator = gpa.allocator();
    const parsed_config = try configFromArgs(allocator, config);
    try playWithAllocator(allocator, parsed_config, Game);
}

pub fn playGame(comptime Game: type) !void {
    comptime validateGame(Game);
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) @panic("game allocation leak");

    const allocator = gpa.allocator();
    const parsed_config = try configFromArgs(allocator, gameConfig(Game));
    try playWithAllocator(allocator, parsed_config, Game);
}

pub fn run(config: Config, state: anytype, comptime callbacks: anytype) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) @panic("game allocation leak");

    const allocator = gpa.allocator();
    const parsed_config = try configFromArgs(allocator, config);
    try runWithAllocator(allocator, parsed_config, state, callbacks);
}

pub fn validateConfig(config: Config) !void {
    if (config.width == 0 or config.height == 0 or config.scale == 0) return error.InvalidConfig;
    if (config.fixed_hz == 0 or config.audio_sample_rate == 0 or config.audio_buffer_frames == 0) return error.InvalidConfig;
    try up.ActionMap.validate(config.actions);
}

fn playWithAllocator(allocator: std.mem.Allocator, config: Config, comptime Game: type) !void {
    const Adapter = struct {
        fn init(state: *Game, ctx: *Context) !void {
            state.* = try initGame(Game, ctx);
        }

        fn deinit(state: *Game, ctx: *Context) void {
            deinitGame(Game, state, ctx);
        }

        fn update(state: *Game, ctx: *Context) !void {
            try callUpdate(Game, state, ctx);
        }

        fn draw(state: *Game, ctx: *Context) !void {
            try callDraw(Game, state, ctx);
        }

        fn event(state: *Game, ctx: *Context, event_value: Event) !void {
            try callEvent(Game, state, ctx, event_value);
        }
    };
    var game: Game = undefined;
    try runWithAllocator(allocator, config, &game, .{
        .init = Adapter.init,
        .deinit = Adapter.deinit,
        .update = Adapter.update,
        .draw = Adapter.draw,
        .event = Adapter.event,
    });
}

fn runWithAllocator(allocator: std.mem.Allocator, config: Config, state: anytype, comptime callbacks: anytype) !void {
    comptime validateLoopCallbacks(callbacks);
    try validateConfig(config);
    if (!c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_EVENTS)) return sdlRendererFail("SDL_Init");
    defer c.SDL_Quit();

    const window_w = try scaledInt(config.width, config.scale);
    const window_h = try scaledInt(config.height, config.scale);
    const window_flags: c.SDL_WindowFlags = if (config.resizable) c.SDL_WINDOW_RESIZABLE else 0;
    const window = c.SDL_CreateWindow(config.title.ptr, window_w, window_h, window_flags) orelse return sdlRendererFail("SDL_CreateWindow");
    defer c.SDL_DestroyWindow(window);

    const device = c.SDL_CreateGPUDevice(requiredGpuShaderFormats(), true, null) orelse return sdlRendererFail("SDL_CreateGPUDevice");
    defer c.SDL_DestroyGPUDevice(device);
    _ = try selectGpuShaderFormat(device);

    if (!c.SDL_ClaimWindowForGPUDevice(device, window)) return sdlGpuFail(device, "SDL_ClaimWindowForGPUDevice");
    defer c.SDL_ReleaseWindowFromGPUDevice(device, window);

    if (!c.SDL_SetGPUSwapchainParameters(device, window, c.SDL_GPU_SWAPCHAINCOMPOSITION_SDR, c.SDL_GPU_PRESENTMODE_VSYNC)) {
        return sdlGpuFail(device, "SDL_SetGPUSwapchainParameters");
    }

    var canvas = try up.Canvas.init(allocator, config.width, config.height);
    defer canvas.deinit();

    var assets = if (config.asset_root) |root_path|
        try up.AssetStore.initAbsolute(allocator, root_path)
    else
        try up.AssetStore.initExecutable(allocator);
    defer assets.deinit();
    var sprite_batch = up.SpriteBatch.init(allocator);
    defer sprite_batch.deinit();
    var commands = up.RenderCommandBuffer.init(allocator);
    defer commands.deinit();
    var pixel_effects = up.PostProcessChain{};
    var inspector = up.Inspector.init(allocator, config.developer_tools);
    defer inspector.deinit();
    var profiler = up.FrameProfiler.init(config.cpu_profiler);
    var runtime_metrics = up.RuntimeMetrics{};
    var frame_metrics = up.RuntimeMetrics{};
    var metrics_panel = up.InspectorMetricsPanel{ .metrics = &runtime_metrics };
    try inspector.register(metrics_panel.panel());
    var capture_requested = false;

    var audio = try up.AudioMixer.init(allocator, .{ .sample_rate = config.audio_sample_rate });
    defer audio.deinit();

    var audio_output = try AudioOutput.init(allocator, config.audio_sample_rate, config.audio_buffer_frames, config.strict_audio);
    defer if (audio_output) |*output| output.deinit(allocator);

    var input = up.Input{};
    var desktop_state = DesktopState{};
    var presentation = up.Presentation.init(.{ .x = @floatFromInt(config.width), .y = @floatFromInt(config.height) }, try framebufferSize(window), config.presentation_mode);
    var clock = up.StepClock.init(config.fixed_hz);
    const data_path = try appDataPath(allocator, config.organization, config.application);
    defer allocator.free(data_path);
    var actions = try up.ActionMap.init(allocator, config.actions);
    defer actions.deinit();
    actions.attachAppData(data_path);
    actions.loadAppData() catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    var dev = try DeveloperTools.init(allocator, config.developer_tools, data_path);
    defer dev.deinit();
    var presenter = try Presenter.init(device, config.width, config.height);
    var presenter_live = true;
    defer if (presenter_live) presenter.deinit(device);

    var ctx = Context{ .allocator = allocator, .canvas = &canvas, .input = &input, .actions = &actions, .assets = &assets, .audio = &audio, .app_data_path = data_path, .presentation = &presentation, .sprite_batch = &sprite_batch, .commands = &commands, .pixel_effects = &pixel_effects, .inspector = &inspector, .profiler = &profiler, .runtime_metrics = &runtime_metrics, .capture_requested = &capture_requested, .dt = 0, .frame = 0 };
    var failure: ?Failure = null;
    var gpu_recovery = GpuRecovery.ready;
    var initialized = false;
    profiler.beginFrame(ctx.frame);
    const init_timer = profiler.scope(.callback);
    callLoopInit(state, callbacks, &ctx) catch |err| {
        dev.failure(.init, err);
        failure = .{ .phase = .init, .err = err };
    };
    init_timer.end();
    if (failure) |current| dev.captureFailure(current, ctx.frame, canvas, commands.commands.items, &profiler);
    initialized = failure == null;
    defer if (initialized) callLoopDeinit(state, callbacks, &ctx);

    var running = true;
    var last_ticks = c.SDL_GetTicksNS();

    while (running) {
        profiler.beginFrame(ctx.frame);
        frame_metrics.beginFrame(ctx.frame);
        input.beginFrame();
        sprite_batch.clear();
        commands.commands.clearRetainingCapacity();
        refreshPresentation(window, &presentation);
        var audio_device_changed = false;
        var close_requested = false;
        const callback_timer = profiler.scope(.callback);
        running = pollInput(state, callbacks, initialized and failure == null, &ctx, &input, window, &presentation, &audio_device_changed, &close_requested, &desktop_state, &gpu_recovery) catch |err| blk: {
            dev.failure(.event, err);
            dev.captureFailure(.{ .phase = .event, .err = err }, ctx.frame, canvas, commands.commands.items, &profiler);
            failure = .{ .phase = .event, .err = err };
            break :blk !close_requested;
        };
        callback_timer.end();
        actions.update(input);
        switch (gpu_recovery) {
            .ready => {},
            .reset_pending => {
                presenter.deinit(device);
                presenter_live = false;
                presenter = Presenter.init(device, config.width, config.height) catch |err| {
                    dev.failure(.gpu_recovery, err);
                    dev.captureFailure(.{ .phase = .gpu_recovery, .err = err }, ctx.frame, canvas, commands.commands.items, &profiler);
                    failure = .{ .phase = .gpu_recovery, .err = err };
                    continue;
                };
                presenter_live = true;
                gpu_recovery = .ready;
            },
            .lost => {
                dev.failure(.gpu_recovery, error.GpuDeviceLost);
                dev.captureFailure(.{ .phase = .gpu_recovery, .err = error.GpuDeviceLost }, ctx.frame, canvas, commands.commands.items, &profiler);
                failure = .{ .phase = .gpu_recovery, .err = error.GpuDeviceLost };
            },
        }
        if (failure) |current| {
            drawFailure(&canvas, current);
            try presenter.present(device, window, canvas, &sprite_batch, commands.commands.items, pixel_effects.items(), null, &presentation, &frame_metrics);
            runtime_metrics = frame_metrics;
            running = advanceFrame(&ctx.frame, config.max_frames) and running;
            continue;
        }
        if (audio_device_changed) {
            if (audio_output) |*output| output.deinit(allocator);
            audio_output = try AudioOutput.init(allocator, config.audio_sample_rate, config.audio_buffer_frames, config.strict_audio);
        }
        if (input.wasPressed(.debug)) dev.toggleOverlay();

        const asset_timer = profiler.scope(.asset);
        const reload_events = assets.reloadChanged() catch |err| {
            asset_timer.end();
            dev.failure(.asset_reload, err);
            dev.captureFailure(.{ .phase = .asset_reload, .err = err }, ctx.frame, canvas, commands.commands.items, &profiler);
            failure = .{ .phase = .asset_reload, .err = err };
            continue;
        };
        asset_timer.end();
        frame_metrics.recordAssetReloads(reload_events.len);

        const now = c.SDL_GetTicksNS();
        const dt = ticksToSeconds(now - last_ticks);
        last_ticks = now;
        const paused = shouldPause(config.pause_policy, desktop_state);

        const steps = if (paused) 0 else clock.push(dt);
        var step: u32 = 0;
        while (step < steps) : (step += 1) {
            ctx.dt = clock.step_seconds;
            const update_timer = profiler.scope(.update);
            callLoopUpdate(state, callbacks, &ctx) catch |err| {
                update_timer.end();
                dev.failure(.update, err);
                dev.captureFailure(.{ .phase = .update, .err = err }, ctx.frame, canvas, commands.commands.items, &profiler);
                failure = .{ .phase = .update, .err = err };
                break;
            };
            update_timer.end();
        }
        if (failure != null) continue;

        canvas.clear(config.clear_color);
        ctx.dt = if (paused) 0 else dt;
        const draw_timer = profiler.scope(.draw);
        callLoopDraw(state, callbacks, &ctx) catch |err| {
            draw_timer.end();
            dev.failure(.draw, err);
            dev.captureFailure(.{ .phase = .draw, .err = err }, ctx.frame, canvas, commands.commands.items, &profiler);
            failure = .{ .phase = .draw, .err = err };
            continue;
        };
        draw_timer.end();
        inspector.draw(&canvas, .{ .context = &dev, .failure = DeveloperTools.inspectorFailure });
        drawReloadOverlay(&canvas, reload_events);
        dev.drawOverlay(&canvas, dt, ctx.frame);
        var screenshot_path: ?[]u8 = null;
        if ((input.wasPressed(.screenshot) and dev.enabled) or capture_requested) {
            screenshot_path = dev.screenshotPath(ctx.frame) catch |err| blk: {
                dev.failure(.screenshot_path, err);
                dev.captureFailure(.{ .phase = .screenshot_path, .err = err }, ctx.frame, canvas, commands.commands.items, &profiler);
                break :blk null;
            };
        }
        defer if (screenshot_path) |path| allocator.free(path);
        if (audio_output) |*output| {
            try output.queue(&audio);
            frame_metrics.recordAudio(output.bufferBytes(), output.queuedBytes());
        }
        try presenter.present(device, window, canvas, &sprite_batch, commands.commands.items, pixel_effects.items(), screenshot_path, &presentation, &frame_metrics);
        runtime_metrics = frame_metrics;
        if (screenshot_path) |path| dev.noteScreenshot(path);
        capture_requested = false;

        running = advanceFrame(&ctx.frame, config.max_frames) and running;
    }

    _ = c.SDL_WaitForGPUIdle(device);
}

fn initGame(comptime Game: type, ctx: *Context) !Game {
    if (@hasDecl(Game, "init")) {
        return try unwrap(Game, Game.init(ctx));
    }
    return .{};
}

fn validateGame(comptime Game: type) void {
    switch (@typeInfo(Game)) {
        .@"struct" => {},
        else => @compileError("Game must be a struct with optional init, event, update, draw, and deinit callbacks"),
    }
}

fn gameConfig(comptime Game: type) Config {
    comptime validateGame(Game);
    if (!@hasDecl(Game, "config")) @compileError("structured Game must declare pub const config: sdl.Config");
    const config = Game.config;
    if (@TypeOf(config) != Config) @compileError("structured Game.config must be sdl.Config");
    return config;
}

fn deinitGame(comptime Game: type, game: *Game, ctx: *Context) void {
    if (@hasDecl(Game, "deinit")) {
        game.deinit(ctx);
    }
}

fn callUpdate(comptime Game: type, game: *Game, ctx: *Context) !void {
    if (@hasDecl(Game, "update")) {
        try maybeError(game.update(ctx));
    }
}

fn callDraw(comptime Game: type, game: *Game, ctx: *Context) !void {
    if (@hasDecl(Game, "draw")) {
        try maybeError(game.draw(ctx));
    }
}

fn callEvent(comptime Game: type, game: *Game, ctx: *Context, event: Event) !void {
    if (@hasDecl(Game, "event")) {
        try maybeError(game.event(ctx, event));
    }
}

fn validateLoopCallbacks(comptime callbacks: anytype) void {
    switch (@typeInfo(@TypeOf(callbacks))) {
        .@"struct" => |info| inline for (info.fields) |field| {
            if (!isLoopCallback(field.name)) @compileError("unknown SDL loop callback: " ++ field.name);
            switch (@typeInfo(@TypeOf(@field(callbacks, field.name)))) {
                .@"fn" => {},
                .pointer => |pointer| switch (@typeInfo(pointer.child)) {
                    .@"fn" => {},
                    else => @compileError("SDL loop callbacks must be functions"),
                },
                else => @compileError("SDL loop callbacks must be functions"),
            }
        },
        else => @compileError("SDL loop callbacks must be a struct literal"),
    }
}

fn isLoopCallback(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "init") or std.mem.eql(u8, name, "deinit") or std.mem.eql(u8, name, "event") or std.mem.eql(u8, name, "update") or std.mem.eql(u8, name, "draw");
}

fn callLoopInit(state: anytype, comptime callbacks: anytype, ctx: *Context) !void {
    if (@hasField(@TypeOf(callbacks), "init")) try maybeError(callbacks.init(state, ctx));
}

fn callLoopDeinit(state: anytype, comptime callbacks: anytype, ctx: *Context) void {
    if (@hasField(@TypeOf(callbacks), "deinit")) maybeError(callbacks.deinit(state, ctx)) catch @panic("SDL loop deinit failed");
}

fn callLoopEvent(state: anytype, comptime callbacks: anytype, ctx: *Context, event_value: Event) !void {
    if (@hasField(@TypeOf(callbacks), "event")) try maybeError(callbacks.event(state, ctx, event_value));
}

fn callLoopUpdate(state: anytype, comptime callbacks: anytype, ctx: *Context) !void {
    if (@hasField(@TypeOf(callbacks), "update")) try maybeError(callbacks.update(state, ctx));
}

fn callLoopDraw(state: anytype, comptime callbacks: anytype, ctx: *Context) !void {
    if (@hasField(@TypeOf(callbacks), "draw")) try maybeError(callbacks.draw(state, ctx));
}

fn unwrap(comptime T: type, value: anytype) !T {
    return switch (@typeInfo(@TypeOf(value))) {
        .error_union => try value,
        else => value,
    };
}

fn maybeError(value: anytype) !void {
    switch (@typeInfo(@TypeOf(value))) {
        .error_union => try value,
        .void => {},
        else => @compileError("runtime callbacks must return void or !void"),
    }
}

test "lifecycle accepts optional callbacks" {
    const DrawOnly = struct {
        pub fn draw(_: *@This(), _: *Context) void {}
    };
    const Full = struct {
        calls: [4]u8 = undefined,
        call_count: usize = 0,

        pub fn init(_: *Context) @This() {
            var game: @This() = .{};
            game.note('i');
            return game;
        }
        pub fn deinit(self: *@This(), _: *Context) void {
            self.note('x');
        }
        pub fn update(self: *@This(), _: *Context) !void {
            self.note('u');
        }
        pub fn draw(self: *@This(), _: *Context) !void {
            self.note('d');
        }
        pub fn event(_: *@This(), _: *Context, _: Event) !void {}

        fn note(self: *@This(), call: u8) void {
            self.calls[self.call_count] = call;
            self.call_count += 1;
        }
    };

    var ctx: Context = undefined;
    var draw_only = try initGame(DrawOnly, &ctx);
    try callUpdate(DrawOnly, &draw_only, &ctx);
    try callDraw(DrawOnly, &draw_only, &ctx);

    var full = try initGame(Full, &ctx);
    try callUpdate(Full, &full, &ctx);
    try callDraw(Full, &full, &ctx);
    try callEvent(Full, &full, &ctx, .close_requested);
    deinitGame(Full, &full, &ctx);
    try std.testing.expectEqualSlices(u8, "iudx", full.calls[0..full.call_count]);
}

test "structured Game owns desktop configuration" {
    const Game = struct {
        pub const config: Config = .{
            .title = "structured",
            .width = 160,
            .height = 90,
            .scale = 4,
            .presentation_mode = .fit,
            .asset_root = "assets",
            .developer_tools = false,
        };
    };
    const config = gameConfig(Game);
    try std.testing.expectEqualStrings("structured", config.title);
    try std.testing.expectEqual(@as(u32, 160), config.width);
    try std.testing.expectEqual(up.PresentationMode.fit, config.presentation_mode);
    try std.testing.expectEqualStrings("assets", config.asset_root.?);
}

test "desktop configuration errors are recoverable" {
    try std.testing.expectError(error.InvalidConfig, validateConfig(.{ .width = 0 }));
    try std.testing.expectError(error.InvalidConfig, validateConfig(.{ .fixed_hz = 0 }));
    try std.testing.expectError(error.InvalidConfig, validateConfig(.{ .audio_sample_rate = 0 }));
    try std.testing.expectError(error.InvalidConfig, validateConfig(.{ .audio_buffer_frames = 0 }));
    try std.testing.expectError(error.DuplicateBinding, validateConfig(.{ .actions = &.{
        .{ .name = "fire", .binding = .{ .key = .action } },
        .{ .name = "fire", .binding = .{ .key = .action } },
    } }));
}

test "desktop pause policy is opt-in and deterministic" {
    try std.testing.expect(!shouldPause(.never, .{ .focused = false, .minimized = true }));
    try std.testing.expect(shouldPause(.unfocused, .{ .focused = false }));
    try std.testing.expect(!shouldPause(.unfocused, .{ .focused = true, .minimized = true }));
    try std.testing.expect(shouldPause(.minimized, .{ .focused = true, .minimized = true }));
}

test "GPU recovery state bounds reset and loss transitions" {
    try std.testing.expectEqual(GpuRecovery.reset_pending, nextGpuRecovery(.ready, .gpu_device_reset));
    try std.testing.expectEqual(GpuRecovery.lost, nextGpuRecovery(.reset_pending, .gpu_device_lost));
    try std.testing.expectEqual(GpuRecovery.lost, nextGpuRecovery(.lost, .gpu_device_reset));
}

test "desktop lifecycle events preserve focus minimize resize and quit order" {
    const State = struct {
        calls: [7]u8 = undefined,
        count: usize = 0,

        fn event(self: *@This(), _: *Context, event_value: Event) void {
            self.calls[self.count] = switch (event_value) {
                .focus_lost => 'f',
                .minimized => 'm',
                .resized => 'r',
                .restored => 's',
                .focus_gained => 'g',
                .close_requested => 'q',
                else => unreachable,
            };
            self.count += 1;
        }
    };
    const callbacks = .{ .event = State.event };
    var ctx: Context = undefined;
    var state = State{};
    for ([_]Event{
        .focus_lost,
        .minimized,
        .{ .resized = .{ .framebuffer_size = .{ .x = 320, .y = 180 } } },
        .restored,
        .focus_gained,
        .close_requested,
    }) |event_value| try callLoopEvent(&state, callbacks, &ctx, event_value);
    try std.testing.expectEqualSlices(u8, "fmrsgq", state.calls[0..state.count]);
}

test "explicit loop callbacks share the lifecycle" {
    const State = struct {
        calls: [5]u8 = undefined,
        call_count: usize = 0,

        fn init(self: *@This(), _: *Context) void {
            self.note('i');
        }

        fn event(self: *@This(), _: *Context, _: Event) void {
            self.note('e');
        }

        fn update(self: *@This(), _: *Context) void {
            self.note('u');
        }

        fn draw(self: *@This(), _: *Context) void {
            self.note('d');
        }

        fn deinit(self: *@This(), _: *Context) void {
            self.note('x');
        }

        fn note(self: *@This(), call: u8) void {
            self.calls[self.call_count] = call;
            self.call_count += 1;
        }
    };
    const callbacks = .{
        .init = State.init,
        .event = State.event,
        .update = State.update,
        .draw = State.draw,
        .deinit = State.deinit,
    };

    var ctx: Context = undefined;
    var state = State{};
    try callLoopInit(&state, callbacks, &ctx);
    try callLoopEvent(&state, callbacks, &ctx, .close_requested);
    try callLoopUpdate(&state, callbacks, &ctx);
    try callLoopDraw(&state, callbacks, &ctx);
    callLoopDeinit(&state, callbacks, &ctx);
    try std.testing.expectEqualSlices(u8, "ieudx", state.calls[0..state.call_count]);
}

fn drawReloadOverlay(canvas: *up.Canvas, events: []const up.ReloadEvent) void {
    if (events.len == 0) return;

    var y: i32 = 4;
    for (events[0..@min(events.len, 4)]) |event| {
        const label = switch (event.status) {
            .changed => "reload",
            .failed => "reload failed",
        };
        const color = switch (event.status) {
            .changed => up.Color.rgb(113, 232, 162),
            .failed => up.Color.rgb(255, 112, 112),
        };
        canvas.drawText(label, 4, y, color);
        canvas.drawText(event.path, 4, y + 8, color);
        y += 17;
    }
}

const Failure = struct {
    phase: FailurePhase,
    err: anyerror,
};

const DesktopState = struct {
    focused: bool = true,
    minimized: bool = false,
};

const GpuRecovery = enum {
    ready,
    reset_pending,
    lost,
};

fn nextGpuRecovery(current: GpuRecovery, event: Event) GpuRecovery {
    return switch (event) {
        .gpu_device_lost => .lost,
        .gpu_device_reset => if (current == .lost) .lost else .reset_pending,
        else => current,
    };
}

fn shouldPause(policy: PausePolicy, state: DesktopState) bool {
    return switch (policy) {
        .never => false,
        .unfocused => !state.focused,
        .minimized => state.minimized,
    };
}

const FailurePhase = enum {
    init,
    event,
    asset_reload,
    gpu_recovery,
    update,
    draw,
    screenshot_path,

    fn label(self: FailurePhase) []const u8 {
        return switch (self) {
            .init => "init",
            .event => "event",
            .asset_reload => "asset reload",
            .gpu_recovery => "GPU recovery",
            .update => "update",
            .draw => "draw",
            .screenshot_path => "screenshot path",
        };
    }
};

test "runtime failures retain category and render a safe report" {
    try std.testing.expectEqualStrings("asset reload", FailurePhase.asset_reload.label());
    var canvas = try up.Canvas.init(std.testing.allocator, 80, 64);
    defer canvas.deinit();
    drawFailure(&canvas, .{ .phase = .draw, .err = error.DrawFailed });
    try std.testing.expectEqual(up.Color.rgb(41, 18, 24), canvas.get(0, 0).?);
    try std.testing.expectEqual(up.Color.rgb(88, 31, 40), canvas.get(2, 2).?);
}

const DeveloperTools = struct {
    allocator: std.mem.Allocator,
    app_data_path: []const u8,
    enabled: bool,
    overlay: bool,
    log_file: ?std.fs.File = null,

    fn init(allocator: std.mem.Allocator, enabled: bool, app_data_path: []const u8) !DeveloperTools {
        var tools = DeveloperTools{
            .allocator = allocator,
            .app_data_path = app_data_path,
            .enabled = enabled,
            .overlay = enabled,
        };
        if (!enabled) return tools;

        const log_path = try std.fmt.allocPrint(allocator, "{s}unpolished-peas.log", .{app_data_path});
        defer allocator.free(log_path);
        tools.log_file = std.fs.cwd().createFile(log_path, .{ .truncate = false }) catch |err| {
            std.debug.print("unpolished-peas log disabled: {s}\n", .{@errorName(err)});
            return tools;
        };
        if (tools.log_file) |file| file.seekFromEnd(0) catch {};
        tools.note("unpolished-peas: started\n");
        std.debug.print("unpolished-peas app data: {s}\nunpolished-peas log: {s}\n", .{ app_data_path, log_path });
        return tools;
    }

    fn deinit(self: *DeveloperTools) void {
        if (self.log_file) |file| file.close();
        self.* = undefined;
    }

    fn toggleOverlay(self: *DeveloperTools) void {
        if (self.enabled) self.overlay = !self.overlay;
    }

    fn failure(self: *DeveloperTools, phase: FailurePhase, err: anyerror) void {
        var buffer: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buffer, "unpolished-peas {s} failed: {s}\n", .{ phase.label(), @errorName(err) }) catch return;
        if (self.log_file != null) {
            std.debug.print("unpolished-peas {s} failed: {s}; log: {s}unpolished-peas.log\n", .{ phase.label(), @errorName(err), self.app_data_path });
        } else std.debug.print("{s}", .{line});
        self.note(line);
    }

    fn captureFailure(self: *DeveloperTools, failure_value: Failure, frame: u64, canvas: up.Canvas, commands: []const up.RenderCommand, frame_profiler: *const up.FrameProfiler) void {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const configured_path = std.process.getEnvVarOwned(self.allocator, "UP_DIAGNOSTICS_ROOT") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => null,
        };
        defer if (configured_path) |value| self.allocator.free(value);
        const path = configured_path orelse std.fmt.bufPrint(&path_buffer, "{s}diagnostics", .{self.app_data_path}) catch return;
        var message_buffer: [256]u8 = undefined;
        const message = std.fmt.bufPrint(&message_buffer, "runtime failure phase={s} error={s} frame={d}\n", .{ failure_value.phase.label(), @errorName(failure_value.err), frame }) catch return;
        up.diagnostics.capture(self.allocator, .{ .path = path }, .{ .canvas = canvas, .commands = commands, .profiler = frame_profiler, .log = message }) catch |err| {
            var buffer: [192]u8 = undefined;
            const line = std.fmt.bufPrint(&buffer, "unpolished-peas diagnostics failed: {s}\n", .{@errorName(err)}) catch return;
            self.note(line);
        };
    }

    fn screenshotPath(self: *DeveloperTools, frame: u64) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}screenshot-{d}-{d}.png", .{ self.app_data_path, c.SDL_GetTicksNS(), frame });
    }

    fn noteScreenshot(self: *DeveloperTools, path: []const u8) void {
        var buffer: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&buffer, "unpolished-peas screenshot: {s}\n", .{path}) catch return;
        std.debug.print("{s}", .{line});
        self.note(line);
    }

    fn inspectorFailure(context: *anyopaque, panel: []const u8, err: anyerror) void {
        const self: *DeveloperTools = @ptrCast(@alignCast(context));
        var buffer: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buffer, "unpolished-peas inspector panel {s} failed: {s}\n", .{ panel, @errorName(err) }) catch return;
        self.note(line);
    }

    fn drawOverlay(self: DeveloperTools, canvas: *up.Canvas, dt: f32, frame: u64) void {
        if (!self.enabled or !self.overlay) return;
        const fps = if (dt > 0) 1.0 / dt else 0;
        var buffer: [96]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "fps {d:.1} ms {d:.2} f{d}", .{ fps, dt * 1000, frame }) catch return;
        canvas.fillRect(0, 0, @intCast(canvas.width), 10, up.Color.rgba(0, 0, 0, 192));
        canvas.drawText(text, 2, 2, up.Color.rgb(225, 232, 240));
    }

    fn note(self: *DeveloperTools, line: []const u8) void {
        if (self.log_file) |file| file.writeAll(line) catch {};
    }
};

test "developer tools log runtime failure categories" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const data_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/", .{root});
    defer std.testing.allocator.free(data_path);
    var tools = try DeveloperTools.init(std.testing.allocator, true, data_path);
    defer tools.deinit();
    tools.failure(.init, error.InitFailed);
    tools.failure(.update, error.UpdateFailed);
    tools.failure(.draw, error.DrawFailed);
    tools.failure(.asset_reload, error.ReloadFailed);
    DeveloperTools.inspectorFailure(&tools, "scene", error.PanelFailed);
    var data = try std.fs.openDirAbsolute(root, .{});
    defer data.close();
    const log = try data.readFileAlloc(std.testing.allocator, "unpolished-peas.log", 4096);
    defer std.testing.allocator.free(log);
    try std.testing.expect(std.mem.indexOf(u8, log, "init failed: InitFailed") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "update failed: UpdateFailed") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "draw failed: DrawFailed") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "asset reload failed: ReloadFailed") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "inspector panel scene failed: PanelFailed") != null);
}

test "runtime failures capture bounded artifacts" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const data_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/", .{root});
    defer std.testing.allocator.free(data_path);
    var tools = try DeveloperTools.init(std.testing.allocator, false, data_path);
    defer tools.deinit();
    var canvas = try up.Canvas.init(std.testing.allocator, 2, 2);
    defer canvas.deinit();
    canvas.clear(up.Color.white);
    var commands = up.RenderCommandBuffer.init(std.testing.allocator);
    defer commands.deinit();
    try commands.append(.{ .clear = up.Color.black });
    var profiler = up.FrameProfiler.init(true);
    profiler.beginFrame(2);
    profiler.scope(.draw).end();
    tools.captureFailure(.{ .phase = .draw, .err = error.DrawFailed }, 2, canvas, commands.commands.items, &profiler);
    const diagnostics_path = try std.fs.path.join(std.testing.allocator, &.{ root, "diagnostics" });
    defer std.testing.allocator.free(diagnostics_path);
    var directory = try std.fs.openDirAbsolute(diagnostics_path, .{});
    defer directory.close();
    try directory.access("screenshot.png", .{});
    try directory.access("commands.json", .{});
    try directory.access("trace.json", .{});
    try directory.access("failure.log", .{});
}

fn drawFailure(canvas: *up.Canvas, failure: Failure) void {
    canvas.clear(up.Color.rgb(41, 18, 24));
    canvas.fillRect(2, 2, @intCast(canvas.width -| 4), @intCast(canvas.height -| 4), up.Color.rgb(88, 31, 40));
    canvas.drawText("ERROR", 6, 6, up.Color.rgb(255, 225, 225));
    canvas.drawText(failure.phase.label(), 6, 18, up.Color.rgb(255, 198, 74));
    canvas.drawText(@errorName(failure.err), 6, 30, up.Color.rgb(255, 225, 225));
    canvas.drawText("LOG: unpolished-peas.log", 6, 42, up.Color.rgb(225, 225, 225));
    canvas.drawText("ESC TO QUIT", 6, 54, up.Color.rgb(225, 232, 240));
}

fn advanceFrame(frame: *u64, max_frames: ?u32) bool {
    frame.* +%= 1;
    if (max_frames) |max| return frame.* < max;
    return true;
}

const AudioOutput = struct {
    stream: *c.SDL_AudioStream,
    samples: []up.AudioSample,
    interleaved: []f32,
    target_frames: usize,

    fn init(allocator: std.mem.Allocator, sample_rate: u32, buffer_frames: u32, strict: bool) !?AudioOutput {
        if (sample_rate == 0 or buffer_frames == 0) return error.InvalidConfig;
        const frames: usize = buffer_frames;
        const spec = c.SDL_AudioSpec{
            .format = c.SDL_AUDIO_F32,
            .channels = 2,
            .freq = @intCast(sample_rate),
        };
        if (!c.SDL_InitSubSystem(c.SDL_INIT_AUDIO)) return audioFail(strict, "SDL_InitSubSystem");
        errdefer c.SDL_QuitSubSystem(c.SDL_INIT_AUDIO);

        const stream = c.SDL_OpenAudioDeviceStream(c.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, null, null) orelse {
            c.SDL_QuitSubSystem(c.SDL_INIT_AUDIO);
            return audioFail(strict, "SDL_OpenAudioDeviceStream");
        };
        errdefer c.SDL_DestroyAudioStream(stream);
        if (!c.SDL_ResumeAudioStreamDevice(stream)) {
            c.SDL_DestroyAudioStream(stream);
            c.SDL_QuitSubSystem(c.SDL_INIT_AUDIO);
            return audioFail(strict, "SDL_ResumeAudioStreamDevice");
        }

        const samples = try allocator.alloc(up.AudioSample, frames);
        errdefer allocator.free(samples);
        const interleaved = try allocator.alloc(f32, frames * 2);
        errdefer allocator.free(interleaved);
        return .{ .stream = stream, .samples = samples, .interleaved = interleaved, .target_frames = frames * 3 };
    }

    fn deinit(self: *AudioOutput, allocator: std.mem.Allocator) void {
        c.SDL_DestroyAudioStream(self.stream);
        c.SDL_QuitSubSystem(c.SDL_INIT_AUDIO);
        allocator.free(self.interleaved);
        allocator.free(self.samples);
        self.* = undefined;
    }

    fn queue(self: *AudioOutput, mixer: *up.AudioMixer) !void {
        const frame_bytes = @as(usize, 2 * @sizeOf(f32));
        var queued_bytes = c.SDL_GetAudioStreamQueued(self.stream);
        if (queued_bytes < 0) return sdlFail("SDL_GetAudioStreamQueued");
        while (@as(usize, @intCast(queued_bytes)) / frame_bytes < self.target_frames) {
            try mixer.mix(self.samples);
            for (self.samples, 0..) |sample, i| {
                self.interleaved[i * 2] = sample.left;
                self.interleaved[i * 2 + 1] = sample.right;
            }
            const byte_len = self.interleaved.len * @sizeOf(f32);
            if (byte_len > std.math.maxInt(c_int)) return error.InvalidConfig;
            if (!c.SDL_PutAudioStreamData(self.stream, self.interleaved.ptr, @intCast(byte_len))) return sdlFail("SDL_PutAudioStreamData");
            queued_bytes += @intCast(byte_len);
        }
    }

    fn bufferBytes(self: *const AudioOutput) u64 {
        return @as(u64, @intCast(self.samples.len * @sizeOf(up.AudioSample) + self.interleaved.len * @sizeOf(f32)));
    }

    fn queuedBytes(self: *const AudioOutput) ?u64 {
        const queued = c.SDL_GetAudioStreamQueued(self.stream);
        if (queued < 0) return null;
        return @intCast(queued);
    }
};

const Presenter = struct {
    render_target: *c.SDL_GPUTexture,
    effect_texture: *c.SDL_GPUTexture,
    transfer: *c.SDL_GPUTransferBuffer,
    width: u32,
    height: u32,
    byte_len: u32,
    resources: up.GpuResources,
    render_target_handle: up.RenderTargetHandle,
    sprite_textures: std.ArrayList(SpriteTexture) = .empty,
    sprite_pipeline: ?*c.SDL_GPUGraphicsPipeline = null,
    effect_pipeline: ?*c.SDL_GPUGraphicsPipeline = null,
    nearest_sampler: ?*c.SDL_GPUSampler = null,
    linear_sampler: ?*c.SDL_GPUSampler = null,
    vertex_buffer: ?*c.SDL_GPUBuffer = null,
    vertex_transfer: ?*c.SDL_GPUTransferBuffer = null,
    vertex_capacity: u32 = 0,
    primitive_batch: up.PrimitiveBatch,
    primitive_alpha_pipeline: ?*c.SDL_GPUGraphicsPipeline = null,
    primitive_additive_pipeline: ?*c.SDL_GPUGraphicsPipeline = null,
    primitive_buffer: ?*c.SDL_GPUBuffer = null,
    primitive_transfer: ?*c.SDL_GPUTransferBuffer = null,
    primitive_capacity: u32 = 0,
    frame: u64 = 0,

    const SpriteTexture = struct {
        image: *const up.Image,
        texture: *c.SDL_GPUTexture,
        transfer: *c.SDL_GPUTransferBuffer,
        pixels: [*]const up.Color,
        width: u32,
        height: u32,
        uploaded: bool = false,
        pending: ?PendingTexture = null,
        last_used_frame: u64 = 0,

        const PendingTexture = struct {
            texture: *c.SDL_GPUTexture,
            transfer: *c.SDL_GPUTransferBuffer,
            pixels: [*]const up.Color,
            width: u32,
            height: u32,
        };

        fn matches(self: SpriteTexture, image: *const up.Image) bool {
            return self.pixels == image.pixels.ptr and self.width == image.width and self.height == image.height;
        }
    };

    fn init(device: *c.SDL_GPUDevice, width: u32, height: u32) !Presenter {
        const byte_len = try checkedByteLen(width, height);
        const render_target = c.SDL_CreateGPUTexture(device, &.{
            .type = c.SDL_GPU_TEXTURETYPE_2D,
            .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
            .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER | c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET,
            .width = width,
            .height = height,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
            .props = 0,
        }) orelse return sdlFail("SDL_CreateGPUTexture");
        errdefer c.SDL_ReleaseGPUTexture(device, render_target);

        const effect_texture = c.SDL_CreateGPUTexture(device, &.{
            .type = c.SDL_GPU_TEXTURETYPE_2D,
            .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
            .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER | c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET,
            .width = width,
            .height = height,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
            .props = 0,
        }) orelse return sdlFail("SDL_CreateGPUTexture");
        errdefer c.SDL_ReleaseGPUTexture(device, effect_texture);

        const transfer = c.SDL_CreateGPUTransferBuffer(device, &.{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = byte_len,
            .props = 0,
        }) orelse return sdlFail("SDL_CreateGPUTransferBuffer");
        errdefer c.SDL_ReleaseGPUTransferBuffer(device, transfer);

        var resources = up.GpuResources.init(std.heap.page_allocator);
        const render_target_handle = try resources.createRenderTarget();
        var presenter = Presenter{ .render_target = render_target, .effect_texture = effect_texture, .transfer = transfer, .width = width, .height = height, .byte_len = byte_len, .resources = resources, .render_target_handle = render_target_handle, .primitive_batch = up.PrimitiveBatch.init(std.heap.page_allocator) };
        errdefer presenter.deinit(device);
        presenter.nearest_sampler = try createSpriteSampler(device, .nearest);
        presenter.linear_sampler = try createSpriteSampler(device, .linear);
        presenter.sprite_pipeline = try createSpritePipeline(device);
        presenter.effect_pipeline = try createEffectPipeline(device);
        presenter.primitive_alpha_pipeline = try createPrimitivePipeline(device, .alpha);
        presenter.primitive_additive_pipeline = try createPrimitivePipeline(device, .additive);
        return presenter;
    }

    fn deinit(self: *Presenter, device: *c.SDL_GPUDevice) void {
        if (self.sprite_pipeline) |pipeline| c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);
        if (self.effect_pipeline) |pipeline| c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);
        if (self.nearest_sampler) |sampler| c.SDL_ReleaseGPUSampler(device, sampler);
        if (self.linear_sampler) |sampler| c.SDL_ReleaseGPUSampler(device, sampler);
        if (self.vertex_buffer) |buffer| c.SDL_ReleaseGPUBuffer(device, buffer);
        if (self.vertex_transfer) |transfer| c.SDL_ReleaseGPUTransferBuffer(device, transfer);
        if (self.primitive_alpha_pipeline) |pipeline| c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);
        if (self.primitive_additive_pipeline) |pipeline| c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);
        if (self.primitive_buffer) |buffer| c.SDL_ReleaseGPUBuffer(device, buffer);
        if (self.primitive_transfer) |transfer| c.SDL_ReleaseGPUTransferBuffer(device, transfer);
        self.primitive_batch.deinit();
        for (self.sprite_textures.items) |sprite| {
            c.SDL_ReleaseGPUTransferBuffer(device, sprite.transfer);
            c.SDL_ReleaseGPUTexture(device, sprite.texture);
            if (sprite.pending) |pending| {
                c.SDL_ReleaseGPUTransferBuffer(device, pending.transfer);
                c.SDL_ReleaseGPUTexture(device, pending.texture);
            }
        }
        self.sprite_textures.deinit(std.heap.page_allocator);
        c.SDL_ReleaseGPUTransferBuffer(device, self.transfer);
        c.SDL_ReleaseGPUTexture(device, self.effect_texture);
        c.SDL_ReleaseGPUTexture(device, self.render_target);
        self.resources.invalidateAll();
        self.resources.deinit();
        self.* = undefined;
    }

    fn present(self: *Presenter, device: *c.SDL_GPUDevice, window: *c.SDL_Window, canvas: up.Canvas, sprites: *up.SpriteBatch, commands: []const up.RenderCommand, effects: []const up.PixelEffect, capture_path: ?[]const u8, presentation: *up.Presentation, metrics: *up.RuntimeMetrics) !void {
        var encoder_timer = std.time.Timer.start() catch unreachable;
        var pass_count: u32 = 1;
        self.frame +%= 1;
        try sprites.sortByTexture();
        for (sprites.batches.items) |batch| _ = try self.spriteTexture(device, batch.image);
        self.primitive_batch.clear();
        try appendPrimitiveCommands(&self.primitive_batch, self.width, self.height, commands);

        const command = c.SDL_AcquireGPUCommandBuffer(device) orelse return sdlFail("SDL_AcquireGPUCommandBuffer");
        var acquired_swapchain = false;
        errdefer {
            if (!acquired_swapchain) _ = c.SDL_CancelGPUCommandBuffer(command);
        }

        const copy_pass = c.SDL_BeginGPUCopyPass(command) orelse return sdlFail("SDL_BeginGPUCopyPass");
        try self.copyCanvas(device, canvas);
        c.SDL_UploadToGPUTexture(copy_pass, &.{
            .transfer_buffer = self.transfer,
            .offset = 0,
            .pixels_per_row = self.width,
            .rows_per_layer = self.height,
        }, &.{
            .texture = self.render_target,
            .mip_level = 0,
            .layer = 0,
            .x = 0,
            .y = 0,
            .z = 0,
            .w = self.width,
            .h = self.height,
            .d = 1,
        }, false);
        for (self.sprite_textures.items) |*sprite| {
            if (!sprite.uploaded) {
                try self.uploadSprite(device, copy_pass, sprite);
                sprite.uploaded = true;
            }
            if (sprite.pending != null) try self.commitPendingSprite(device, copy_pass, sprite);
        }
        if (sprites.vertices.items.len != 0) try self.uploadVertices(device, copy_pass, sprites.vertices.items);
        if (self.primitive_batch.vertices.items.len != 0) try self.uploadPrimitiveVertices(device, copy_pass, self.primitive_batch.vertices.items);
        c.SDL_EndGPUCopyPass(copy_pass);

        if (self.primitive_batch.vertices.items.len != 0) {
            try self.renderPrimitives(command);
            pass_count +%= 1;
        }
        if (sprites.vertices.items.len != 0) {
            try self.renderSprites(command, sprites);
            pass_count +%= 1;
        }
        var display_texture = self.render_target;
        for (effects) |effect| {
            const target = if (display_texture == self.render_target) self.effect_texture else self.render_target;
            display_texture = try self.renderPixelEffect(command, display_texture, target, effect);
            pass_count +%= 1;
        }
        var capture_transfer: ?*c.SDL_GPUTransferBuffer = null;
        if (capture_path != null) {
            capture_transfer = try self.downloadTexture(device, command, display_texture);
            pass_count +%= 1;
        }
        errdefer if (capture_transfer) |transfer| c.SDL_ReleaseGPUTransferBuffer(device, transfer);

        var swapchain: ?*c.SDL_GPUTexture = null;
        var swap_w: u32 = 0;
        var swap_h: u32 = 0;
        if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(command, window, &swapchain, &swap_w, &swap_h)) {
            return sdlFail("SDL_WaitAndAcquireGPUSwapchainTexture");
        }
        acquired_swapchain = true;
        if (swapchainAvailable(swapchain)) {
            pass_count +%= 1;
            const target = swapchain.?;
            updateFramebufferSize(presentation, swap_w, swap_h);
            const destination = presentation.destination();
            c.SDL_BlitGPUTexture(command, &.{
                .source = .{
                    .texture = display_texture,
                    .mip_level = 0,
                    .layer_or_depth_plane = 0,
                    .x = 0,
                    .y = 0,
                    .w = self.width,
                    .h = self.height,
                },
                .destination = .{
                    .texture = target,
                    .mip_level = 0,
                    .layer_or_depth_plane = 0,
                    .x = @intFromFloat(@round(destination.x)),
                    .y = @intFromFloat(@round(destination.y)),
                    .w = @intFromFloat(@round(destination.w)),
                    .h = @intFromFloat(@round(destination.h)),
                },
                .load_op = c.SDL_GPU_LOADOP_CLEAR,
                .clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
                .flip_mode = c.SDL_FLIP_NONE,
                .filter = c.SDL_GPU_FILTER_NEAREST,
                .cycle = false,
                .padding1 = 0,
                .padding2 = 0,
                .padding3 = 0,
            });
        }

        if (capture_transfer) |transfer| {
            const fence = c.SDL_SubmitGPUCommandBufferAndAcquireFence(command) orelse return sdlFail("SDL_SubmitGPUCommandBufferAndAcquireFence");
            defer c.SDL_ReleaseGPUFence(device, fence);
            const fences = [_]*c.SDL_GPUFence{fence};
            if (!c.SDL_WaitForGPUFences(device, true, &fences, 1)) return sdlFail("SDL_WaitForGPUFences");
            try self.writeCapturedPng(device, transfer, capture_path.?);
            c.SDL_ReleaseGPUTransferBuffer(device, transfer);
            capture_transfer = null;
        } else if (!c.SDL_SubmitGPUCommandBuffer(command)) return sdlFail("SDL_SubmitGPUCommandBuffer");
        self.reclaimUnusedSprites(device);
        metrics.recordGpuSubmission(encoder_timer.read(), pass_count, @intCast(sprites.batches.items.len), self.textureCount(), self.textureBytes(), self.allocationBytes(sprites));
    }

    fn textureCount(self: *const Presenter) u32 {
        var count: u32 = 2;
        for (self.sprite_textures.items) |sprite| {
            count +%= 1;
            if (sprite.pending != null) count +%= 1;
        }
        return count;
    }

    fn textureBytes(self: *const Presenter) u64 {
        var bytes = @as(u64, self.byte_len) * 2;
        for (self.sprite_textures.items) |sprite| {
            bytes +|= imageBytes(sprite.width, sprite.height);
            if (sprite.pending) |pending| bytes +|= imageBytes(pending.width, pending.height);
        }
        return bytes;
    }

    fn allocationBytes(self: *const Presenter, sprites: *const up.SpriteBatch) u64 {
        var bytes = @as(u64, self.vertex_capacity) + @as(u64, self.primitive_capacity);
        bytes +|= @as(u64, @intCast(sprites.draws.capacity)) * @sizeOf(up.SpriteBatchDraw);
        bytes +|= @as(u64, @intCast(sprites.vertices.capacity)) * @sizeOf(up.SpriteBatchVertex);
        bytes +|= @as(u64, @intCast(sprites.sorted.capacity)) * @sizeOf(usize);
        bytes +|= @as(u64, @intCast(sprites.batches.capacity)) * @sizeOf(up.SpriteBatchGroup);
        bytes +|= @as(u64, @intCast(self.primitive_batch.vertices.capacity)) * @sizeOf(up.PrimitiveBatchVertex);
        bytes +|= @as(u64, @intCast(self.primitive_batch.draws.capacity)) * @sizeOf(up.PrimitiveBatchDraw);
        return bytes;
    }

    fn imageBytes(width: u32, height: u32) u64 {
        return @as(u64, width) * @as(u64, height) * 4;
    }

    fn downloadTexture(self: *Presenter, device: *c.SDL_GPUDevice, command: *c.SDL_GPUCommandBuffer, texture: *c.SDL_GPUTexture) !*c.SDL_GPUTransferBuffer {
        const transfer = c.SDL_CreateGPUTransferBuffer(device, &.{ .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD, .size = self.byte_len, .props = 0 }) orelse return sdlFail("SDL_CreateGPUTransferBuffer");
        errdefer c.SDL_ReleaseGPUTransferBuffer(device, transfer);
        const copy_pass = c.SDL_BeginGPUCopyPass(command) orelse return sdlFail("SDL_BeginGPUCopyPass");
        c.SDL_DownloadFromGPUTexture(copy_pass, &.{ .texture = texture, .mip_level = 0, .layer = 0, .x = 0, .y = 0, .z = 0, .w = self.width, .h = self.height, .d = 1 }, &.{ .transfer_buffer = transfer, .offset = 0, .pixels_per_row = self.width, .rows_per_layer = self.height });
        c.SDL_EndGPUCopyPass(copy_pass);
        return transfer;
    }

    fn writeCapturedPng(self: *Presenter, device: *c.SDL_GPUDevice, transfer: *c.SDL_GPUTransferBuffer, path: []const u8) !void {
        const mapped = c.SDL_MapGPUTransferBuffer(device, transfer, false) orelse return sdlFail("SDL_MapGPUTransferBuffer");
        defer c.SDL_UnmapGPUTransferBuffer(device, transfer);
        const bytes: [*]const u8 = @ptrCast(mapped);
        var canvas = try canvasFromRgba(std.heap.page_allocator, self.width, self.height, bytes[0..self.byte_len]);
        defer canvas.deinit();
        try canvas.writePngFile(path);
    }

    fn copyCanvas(self: *Presenter, device: *c.SDL_GPUDevice, canvas: up.Canvas) !void {
        std.debug.assert(canvas.width == self.width);
        std.debug.assert(canvas.height == self.height);

        const mapped = c.SDL_MapGPUTransferBuffer(device, self.transfer, true) orelse return sdlFail("SDL_MapGPUTransferBuffer");
        defer c.SDL_UnmapGPUTransferBuffer(device, self.transfer);

        const dst: [*]u8 = @ptrCast(mapped);
        var i: usize = 0;
        for (canvas.pixels) |p| {
            dst[i] = p.r;
            dst[i + 1] = p.g;
            dst[i + 2] = p.b;
            dst[i + 3] = p.a;
            i += 4;
        }
    }

    fn uploadPrimitiveVertices(self: *Presenter, device: *c.SDL_GPUDevice, copy_pass: *c.SDL_GPUCopyPass, vertices: []const up.PrimitiveBatchVertex) !void {
        const byte_len = std.math.cast(u32, std.mem.sliceAsBytes(vertices).len) orelse return error.PrimitiveBatchTooLarge;
        try self.ensurePrimitiveCapacity(device, byte_len);
        const transfer = self.primitive_transfer orelse unreachable;
        const mapped = c.SDL_MapGPUTransferBuffer(device, transfer, true) orelse return sdlFail("SDL_MapGPUTransferBuffer");
        defer c.SDL_UnmapGPUTransferBuffer(device, transfer);
        const dst: [*]u8 = @ptrCast(mapped);
        @memcpy(dst[0..byte_len], std.mem.sliceAsBytes(vertices));
        c.SDL_UploadToGPUBuffer(copy_pass, &.{ .transfer_buffer = transfer, .offset = 0 }, &.{ .buffer = self.primitive_buffer orelse unreachable, .offset = 0, .size = byte_len }, true);
    }

    fn ensurePrimitiveCapacity(self: *Presenter, device: *c.SDL_GPUDevice, needed: u32) !void {
        if (needed <= self.primitive_capacity) return;
        var capacity: u32 = 4096;
        while (capacity < needed) capacity = std.math.mul(u32, capacity, 2) catch return error.PrimitiveBatchTooLarge;
        const buffer = c.SDL_CreateGPUBuffer(device, &.{ .usage = c.SDL_GPU_BUFFERUSAGE_VERTEX, .size = capacity, .props = 0 }) orelse return sdlFail("SDL_CreateGPUBuffer");
        errdefer c.SDL_ReleaseGPUBuffer(device, buffer);
        const transfer = c.SDL_CreateGPUTransferBuffer(device, &.{ .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD, .size = capacity, .props = 0 }) orelse return sdlFail("SDL_CreateGPUTransferBuffer");
        if (self.primitive_buffer) |old| c.SDL_ReleaseGPUBuffer(device, old);
        if (self.primitive_transfer) |old| c.SDL_ReleaseGPUTransferBuffer(device, old);
        self.primitive_buffer = buffer;
        self.primitive_transfer = transfer;
        self.primitive_capacity = capacity;
    }

    fn renderPrimitives(self: *Presenter, command: *c.SDL_GPUCommandBuffer) !void {
        var color_target = c.SDL_GPUColorTargetInfo{
            .texture = self.render_target,
            .mip_level = 0,
            .layer_or_depth_plane = 0,
            .clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .load_op = c.SDL_GPU_LOADOP_LOAD,
            .store_op = c.SDL_GPU_STOREOP_STORE,
            .resolve_texture = null,
            .resolve_mip_level = 0,
            .resolve_layer = 0,
            .cycle = false,
            .cycle_resolve_texture = false,
            .padding1 = 0,
            .padding2 = 0,
        };
        const pass = c.SDL_BeginGPURenderPass(command, &color_target, 1, null) orelse return sdlFail("SDL_BeginGPURenderPass");
        defer c.SDL_EndGPURenderPass(pass);
        const buffer = self.primitive_buffer orelse return error.PrimitivePipelineUnavailable;
        for (self.primitive_batch.draws.items) |draw| {
            const pipeline = switch (draw.blend) {
                .alpha => self.primitive_alpha_pipeline orelse return error.PrimitivePipelineUnavailable,
                .additive => self.primitive_additive_pipeline orelse return error.PrimitivePipelineUnavailable,
            };
            c.SDL_BindGPUGraphicsPipeline(pass, pipeline);
            const scissor = primitiveScissor(draw.clip, self.width, self.height);
            c.SDL_SetGPUScissor(pass, &scissor);
            const binding = c.SDL_GPUBufferBinding{ .buffer = buffer, .offset = draw.vertex_start * @sizeOf(up.PrimitiveBatchVertex) };
            c.SDL_BindGPUVertexBuffers(pass, 0, &binding, 1);
            c.SDL_DrawGPUPrimitives(pass, draw.vertex_count, 1, 0, 0);
        }
    }

    fn uploadVertices(self: *Presenter, device: *c.SDL_GPUDevice, copy_pass: *c.SDL_GPUCopyPass, vertices: []const up.SpriteBatchVertex) !void {
        const byte_len = std.math.cast(u32, std.mem.sliceAsBytes(vertices).len) orelse return error.SpriteBatchTooLarge;
        try self.ensureVertexCapacity(device, byte_len);
        const transfer = self.vertex_transfer orelse unreachable;
        const mapped = c.SDL_MapGPUTransferBuffer(device, transfer, true) orelse return sdlFail("SDL_MapGPUTransferBuffer");
        defer c.SDL_UnmapGPUTransferBuffer(device, transfer);
        const dst: [*]u8 = @ptrCast(mapped);
        @memcpy(dst[0..byte_len], std.mem.sliceAsBytes(vertices));
        c.SDL_UploadToGPUBuffer(copy_pass, &.{ .transfer_buffer = transfer, .offset = 0 }, &.{ .buffer = self.vertex_buffer orelse unreachable, .offset = 0, .size = byte_len }, true);
    }

    fn ensureVertexCapacity(self: *Presenter, device: *c.SDL_GPUDevice, needed: u32) !void {
        if (needed <= self.vertex_capacity) return;
        var capacity: u32 = 4096;
        while (capacity < needed) capacity = std.math.mul(u32, capacity, 2) catch return error.SpriteBatchTooLarge;
        const buffer = c.SDL_CreateGPUBuffer(device, &.{ .usage = c.SDL_GPU_BUFFERUSAGE_VERTEX, .size = capacity, .props = 0 }) orelse return sdlFail("SDL_CreateGPUBuffer");
        errdefer c.SDL_ReleaseGPUBuffer(device, buffer);
        const transfer = c.SDL_CreateGPUTransferBuffer(device, &.{ .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD, .size = capacity, .props = 0 }) orelse return sdlFail("SDL_CreateGPUTransferBuffer");
        if (self.vertex_buffer) |old| c.SDL_ReleaseGPUBuffer(device, old);
        if (self.vertex_transfer) |old| c.SDL_ReleaseGPUTransferBuffer(device, old);
        self.vertex_buffer = buffer;
        self.vertex_transfer = transfer;
        self.vertex_capacity = capacity;
    }

    fn renderSprites(self: *Presenter, command: *c.SDL_GPUCommandBuffer, sprites: *up.SpriteBatch) !void {
        const pipeline = self.sprite_pipeline orelse return error.SpritePipelineUnavailable;
        var color_target = c.SDL_GPUColorTargetInfo{
            .texture = self.render_target,
            .mip_level = 0,
            .layer_or_depth_plane = 0,
            .clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .load_op = c.SDL_GPU_LOADOP_LOAD,
            .store_op = c.SDL_GPU_STOREOP_STORE,
            .resolve_texture = null,
            .resolve_mip_level = 0,
            .resolve_layer = 0,
            .cycle = false,
            .cycle_resolve_texture = false,
            .padding1 = 0,
            .padding2 = 0,
        };
        const pass = c.SDL_BeginGPURenderPass(command, &color_target, 1, null) orelse return sdlFail("SDL_BeginGPURenderPass");
        defer c.SDL_EndGPURenderPass(pass);
        c.SDL_BindGPUGraphicsPipeline(pass, pipeline);
        for (sprites.sorted.items) |draw_index| {
            const draw = sprites.draws.items[draw_index];
            const sprite = self.findSprite(draw.image) orelse return error.MissingSpriteTexture;
            const sampler = switch (draw.sampling) {
                .nearest => self.nearest_sampler orelse return error.SpritePipelineUnavailable,
                .linear => self.linear_sampler orelse return error.SpritePipelineUnavailable,
            };
            const texture_sampler = c.SDL_GPUTextureSamplerBinding{ .texture = sprite.texture, .sampler = sampler };
            c.SDL_BindGPUFragmentSamplers(pass, 0, &texture_sampler, 1);
            const binding = c.SDL_GPUBufferBinding{ .buffer = self.vertex_buffer orelse return error.SpritePipelineUnavailable, .offset = draw.vertex_start * @sizeOf(up.SpriteBatchVertex) };
            c.SDL_BindGPUVertexBuffers(pass, 0, &binding, 1);
            c.SDL_DrawGPUPrimitives(pass, 6, 1, 0, 0);
        }
    }

    fn renderPixelEffect(self: *Presenter, command: *c.SDL_GPUCommandBuffer, source: *c.SDL_GPUTexture, target: *c.SDL_GPUTexture, effect: up.PixelEffect) !*c.SDL_GPUTexture {
        if (effect.kind == .passthrough) return source;
        const pipeline = self.effect_pipeline orelse return error.PixelEffectUnavailable;
        const sampler = self.nearest_sampler orelse return error.PixelEffectUnavailable;
        var color_target = c.SDL_GPUColorTargetInfo{
            .texture = target,
            .mip_level = 0,
            .layer_or_depth_plane = 0,
            .clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .load_op = c.SDL_GPU_LOADOP_CLEAR,
            .store_op = c.SDL_GPU_STOREOP_STORE,
            .resolve_texture = null,
            .resolve_mip_level = 0,
            .resolve_layer = 0,
            .cycle = false,
            .cycle_resolve_texture = false,
            .padding1 = 0,
            .padding2 = 0,
        };
        const pass = c.SDL_BeginGPURenderPass(command, &color_target, 1, null) orelse return sdlFail("SDL_BeginGPURenderPass");
        defer c.SDL_EndGPURenderPass(pass);
        c.SDL_BindGPUGraphicsPipeline(pass, pipeline);
        const texture_sampler = c.SDL_GPUTextureSamplerBinding{ .texture = source, .sampler = sampler };
        c.SDL_BindGPUFragmentSamplers(pass, 0, &texture_sampler, 1);
        const parameters = [_]f32{ effect.amount, 0, 0, 0 };
        c.SDL_PushGPUFragmentUniformData(command, 0, &parameters, @sizeOf(@TypeOf(parameters)));
        c.SDL_DrawGPUPrimitives(pass, 6, 1, 0, 0);
        return target;
    }

    fn spriteTexture(self: *Presenter, device: *c.SDL_GPUDevice, image: *const up.Image) !usize {
        for (self.sprite_textures.items, 0..) |*sprite, index| {
            if (sprite.image != image) continue;
            sprite.last_used_frame = self.frame;
            if (!sprite.matches(image)) try self.queueSpriteReplacement(device, sprite, image);
            return index;
        }
        const bytes = std.math.mul(u32, image.width, image.height) catch return error.ImageTooLarge;
        const texture = c.SDL_CreateGPUTexture(device, &.{ .type = c.SDL_GPU_TEXTURETYPE_2D, .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM, .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER, .width = image.width, .height = image.height, .layer_count_or_depth = 1, .num_levels = 1, .sample_count = c.SDL_GPU_SAMPLECOUNT_1, .props = 0 }) orelse return sdlFail("SDL_CreateGPUTexture");
        errdefer c.SDL_ReleaseGPUTexture(device, texture);
        const transfer = c.SDL_CreateGPUTransferBuffer(device, &.{ .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD, .size = try std.math.mul(u32, bytes, 4), .props = 0 }) orelse return sdlFail("SDL_CreateGPUTransferBuffer");
        errdefer c.SDL_ReleaseGPUTransferBuffer(device, transfer);
        try self.sprite_textures.append(std.heap.page_allocator, .{ .image = image, .texture = texture, .transfer = transfer, .pixels = image.pixels.ptr, .width = image.width, .height = image.height, .last_used_frame = self.frame });
        return self.sprite_textures.items.len - 1;
    }

    fn findSprite(self: *Presenter, image: *const up.Image) ?*SpriteTexture {
        for (self.sprite_textures.items) |*sprite| if (sprite.image == image) return sprite;
        return null;
    }

    fn uploadSprite(_: *Presenter, device: *c.SDL_GPUDevice, copy_pass: *c.SDL_GPUCopyPass, sprite: *SpriteTexture) !void {
        try uploadSpriteTexture(device, copy_pass, sprite.image, sprite.texture, sprite.transfer);
    }

    fn queueSpriteReplacement(_: *Presenter, device: *c.SDL_GPUDevice, sprite: *SpriteTexture, image: *const up.Image) !void {
        if (sprite.pending) |pending| {
            if (pending.pixels == image.pixels.ptr and pending.width == image.width and pending.height == image.height) return;
            c.SDL_ReleaseGPUTransferBuffer(device, pending.transfer);
            c.SDL_ReleaseGPUTexture(device, pending.texture);
        }
        const replacement = try createSpriteTexture(device, image);
        sprite.pending = .{ .texture = replacement.texture, .transfer = replacement.transfer, .pixels = image.pixels.ptr, .width = image.width, .height = image.height };
    }

    fn commitPendingSprite(_: *Presenter, device: *c.SDL_GPUDevice, copy_pass: *c.SDL_GPUCopyPass, sprite: *SpriteTexture) !void {
        const pending = sprite.pending orelse return;
        try uploadSpriteTexture(device, copy_pass, sprite.image, pending.texture, pending.transfer);
        c.SDL_ReleaseGPUTransferBuffer(device, sprite.transfer);
        c.SDL_ReleaseGPUTexture(device, sprite.texture);
        sprite.texture = pending.texture;
        sprite.transfer = pending.transfer;
        sprite.pixels = pending.pixels;
        sprite.width = pending.width;
        sprite.height = pending.height;
        sprite.uploaded = true;
        sprite.pending = null;
    }

    fn reclaimUnusedSprites(self: *Presenter, device: *c.SDL_GPUDevice) void {
        var index: usize = 0;
        while (index < self.sprite_textures.items.len) {
            const sprite = self.sprite_textures.items[index];
            if (self.frame -% sprite.last_used_frame <= 120) {
                index += 1;
                continue;
            }
            c.SDL_ReleaseGPUTransferBuffer(device, sprite.transfer);
            c.SDL_ReleaseGPUTexture(device, sprite.texture);
            if (sprite.pending) |pending| {
                c.SDL_ReleaseGPUTransferBuffer(device, pending.transfer);
                c.SDL_ReleaseGPUTexture(device, pending.texture);
            }
            _ = self.sprite_textures.orderedRemove(index);
        }
    }

    fn createSpriteTexture(device: *c.SDL_GPUDevice, image: *const up.Image) !struct { texture: *c.SDL_GPUTexture, transfer: *c.SDL_GPUTransferBuffer } {
        const pixels = std.math.mul(u32, image.width, image.height) catch return error.ImageTooLarge;
        const texture = c.SDL_CreateGPUTexture(device, &.{ .type = c.SDL_GPU_TEXTURETYPE_2D, .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM, .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER, .width = image.width, .height = image.height, .layer_count_or_depth = 1, .num_levels = 1, .sample_count = c.SDL_GPU_SAMPLECOUNT_1, .props = 0 }) orelse return sdlFail("SDL_CreateGPUTexture");
        errdefer c.SDL_ReleaseGPUTexture(device, texture);
        const transfer = c.SDL_CreateGPUTransferBuffer(device, &.{ .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD, .size = try std.math.mul(u32, pixels, 4), .props = 0 }) orelse return sdlFail("SDL_CreateGPUTransferBuffer");
        return .{ .texture = texture, .transfer = transfer };
    }

    fn uploadSpriteTexture(device: *c.SDL_GPUDevice, copy_pass: *c.SDL_GPUCopyPass, image: *const up.Image, texture: *c.SDL_GPUTexture, transfer: *c.SDL_GPUTransferBuffer) !void {
        const mapped = c.SDL_MapGPUTransferBuffer(device, transfer, false) orelse return sdlFail("SDL_MapGPUTransferBuffer");
        defer c.SDL_UnmapGPUTransferBuffer(device, transfer);
        const dst: [*]u8 = @ptrCast(mapped);
        for (image.pixels, 0..) |pixel, index| {
            const offset = index * 4;
            dst[offset] = pixel.r;
            dst[offset + 1] = pixel.g;
            dst[offset + 2] = pixel.b;
            dst[offset + 3] = pixel.a;
        }
        c.SDL_UploadToGPUTexture(copy_pass, &.{ .transfer_buffer = transfer, .offset = 0, .pixels_per_row = image.width, .rows_per_layer = image.height }, &.{ .texture = texture, .mip_level = 0, .layer = 0, .x = 0, .y = 0, .z = 0, .w = image.width, .h = image.height, .d = 1 }, false);
    }
};

fn appendPrimitiveCommands(batch: *up.PrimitiveBatch, width: u32, height: u32, commands: []const up.RenderCommand) !void {
    var clip_stack = std.ArrayList(?up.ClipRect).empty;
    defer clip_stack.deinit(batch.allocator);
    var blend_stack = std.ArrayList(up.BlendMode).empty;
    defer blend_stack.deinit(batch.allocator);
    var clip: ?up.ClipRect = null;
    var blend: up.BlendMode = .alpha;

    for (commands) |command| switch (command) {
        .begin_frame, .clear, .image, .present => {},
        .push_clip => |next| {
            try clip_stack.append(batch.allocator, clip);
            clip = if (clip) |current| intersectClip(current, next) else next;
        },
        .pop_clip => clip = clip_stack.pop() orelse return error.UnbalancedRenderState,
        .push_blend => |next| {
            try blend_stack.append(batch.allocator, blend);
            blend = next;
        },
        .pop_blend => blend = blend_stack.pop() orelse return error.UnbalancedRenderState,
        .rect => |value| {
            const start: u32 = @intCast(batch.vertices.items.len);
            try batch.rect(width, height, value.x, value.y, value.w, value.h, value.color);
            try batch.finishDraw(start, blend, clip);
        },
        .stroke_rect => |value| {
            const start: u32 = @intCast(batch.vertices.items.len);
            try batch.strokeRect(width, height, value.x, value.y, value.w, value.h, value.color);
            try batch.finishDraw(start, blend, clip);
        },
        .circle => |value| {
            const start: u32 = @intCast(batch.vertices.items.len);
            try batch.circle(width, height, .{ .x = @floatFromInt(value.x), .y = @floatFromInt(value.y) }, value.radius, value.color);
            try batch.finishDraw(start, blend, clip);
        },
        .stroke_circle => |value| {
            const start: u32 = @intCast(batch.vertices.items.len);
            try batch.strokeCircle(width, height, .{ .x = @floatFromInt(value.x), .y = @floatFromInt(value.y) }, value.radius, value.color);
            try batch.finishDraw(start, blend, clip);
        },
        .line => |value| {
            const start: u32 = @intCast(batch.vertices.items.len);
            try batch.line(width, height, .{ .x = @floatFromInt(value.x0), .y = @floatFromInt(value.y0) }, .{ .x = @floatFromInt(value.x1), .y = @floatFromInt(value.y1) }, value.color);
            try batch.finishDraw(start, blend, clip);
        },
        .triangle => |value| {
            const start: u32 = @intCast(batch.vertices.items.len);
            try batch.triangle(width, height, .{ .x = value.a.x, .y = value.a.y }, .{ .x = value.b.x, .y = value.b.y }, .{ .x = value.c.x, .y = value.c.y }, value.color);
            try batch.finishDraw(start, blend, clip);
        },
        .stroke_triangle => |value| {
            const start: u32 = @intCast(batch.vertices.items.len);
            try batch.strokeTriangle(width, height, .{ .x = value.a.x, .y = value.a.y }, .{ .x = value.b.x, .y = value.b.y }, .{ .x = value.c.x, .y = value.c.y }, value.color);
            try batch.finishDraw(start, blend, clip);
        },
        .text => |value| {
            const start: u32 = @intCast(batch.vertices.items.len);
            try batch.text(width, height, value.value, value.x, value.y, value.color);
            try batch.finishDraw(start, blend, clip);
        },
    };
    if (clip_stack.items.len != 0 or blend_stack.items.len != 0) return error.UnbalancedRenderState;
}

fn intersectClip(a: up.ClipRect, b: up.ClipRect) up.ClipRect {
    const x = @max(@as(i64, a.x), @as(i64, b.x));
    const y = @max(@as(i64, a.y), @as(i64, b.y));
    const right = @min(@as(i64, a.x) + a.w, @as(i64, b.x) + b.w);
    const bottom = @min(@as(i64, a.y) + a.h, @as(i64, b.y) + b.h);
    return .{ .x = clampI64ToI32(x), .y = clampI64ToI32(y), .w = clampI64ToI32(@max(@as(i64, 0), right - x)), .h = clampI64ToI32(@max(@as(i64, 0), bottom - y)) };
}

fn clampI64ToI32(value: i64) i32 {
    return @intCast(@max(@as(i64, std.math.minInt(i32)), @min(@as(i64, std.math.maxInt(i32)), value)));
}

fn saturatingAdd(a: i32, b: i32) i32 {
    return std.math.add(i32, a, b) catch if (b < 0) std.math.minInt(i32) else std.math.maxInt(i32);
}

fn primitiveScissor(clip: ?up.ClipRect, width: u32, height: u32) c.SDL_Rect {
    const limit_x: i64 = @intCast(width);
    const limit_y: i64 = @intCast(height);
    if (clip) |value| {
        const clip_right = @as(i64, value.x) + @max(@as(i64, 0), @as(i64, value.w));
        const clip_bottom = @as(i64, value.y) + @max(@as(i64, 0), @as(i64, value.h));
        const x0 = @max(@as(i64, 0), @min(limit_x, @as(i64, value.x)));
        const y0 = @max(@as(i64, 0), @min(limit_y, @as(i64, value.y)));
        const x1 = @max(x0, @min(limit_x, clip_right));
        const y1 = @max(y0, @min(limit_y, clip_bottom));
        return .{ .x = clampI64ToCInt(x0), .y = clampI64ToCInt(y0), .w = clampI64ToCInt(x1 - x0), .h = clampI64ToCInt(y1 - y0) };
    }
    return .{ .x = 0, .y = 0, .w = clampI64ToCInt(limit_x), .h = clampI64ToCInt(limit_y) };
}

fn clampI64ToCInt(value: i64) c_int {
    return @intCast(@max(@as(i64, std.math.minInt(c_int)), @min(@as(i64, std.math.maxInt(c_int)), value)));
}

fn createSpriteSampler(device: *c.SDL_GPUDevice, sampling: up.SpriteSampling) !*c.SDL_GPUSampler {
    const filter: c.SDL_GPUFilter = switch (sampling) {
        .nearest => c.SDL_GPU_FILTER_NEAREST,
        .linear => c.SDL_GPU_FILTER_LINEAR,
    };
    return c.SDL_CreateGPUSampler(device, &.{
        .min_filter = filter,
        .mag_filter = filter,
        .mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_NEAREST,
        .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .mip_lod_bias = 0,
        .max_anisotropy = 0,
        .compare_op = c.SDL_GPU_COMPAREOP_NEVER,
        .min_lod = 0,
        .max_lod = 0,
        .enable_anisotropy = false,
        .enable_compare = false,
        .padding1 = 0,
        .padding2 = 0,
        .props = 0,
    }) orelse return sdlFail("SDL_CreateGPUSampler");
}

fn createSpritePipeline(device: *c.SDL_GPUDevice) !*c.SDL_GPUGraphicsPipeline {
    const vertex_shader = try createSpriteShader(device, .vertex);
    defer c.SDL_ReleaseGPUShader(device, vertex_shader);
    const fragment_shader = try createSpriteShader(device, .fragment);
    defer c.SDL_ReleaseGPUShader(device, fragment_shader);
    const target = c.SDL_GPUColorTargetDescription{
        .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
        .blend_state = .{
            .src_color_blendfactor = c.SDL_GPU_BLENDFACTOR_SRC_ALPHA,
            .dst_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
            .color_blend_op = c.SDL_GPU_BLENDOP_ADD,
            .src_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
            .dst_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
            .alpha_blend_op = c.SDL_GPU_BLENDOP_ADD,
            .color_write_mask = 0xF,
            .enable_blend = true,
            .enable_color_write_mask = true,
            .padding1 = 0,
            .padding2 = 0,
        },
    };
    const vertex_buffer = c.SDL_GPUVertexBufferDescription{ .slot = 0, .pitch = @sizeOf(up.SpriteBatchVertex), .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX, .instance_step_rate = 0 };
    const vertex_attributes = [_]c.SDL_GPUVertexAttribute{
        .{ .location = 0, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = @offsetOf(up.SpriteBatchVertex, "x") },
        .{ .location = 1, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = @offsetOf(up.SpriteBatchVertex, "u") },
        .{ .location = 2, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4, .offset = @offsetOf(up.SpriteBatchVertex, "r") },
    };
    return c.SDL_CreateGPUGraphicsPipeline(device, &.{
        .vertex_shader = vertex_shader,
        .fragment_shader = fragment_shader,
        .vertex_input_state = .{ .vertex_buffer_descriptions = &vertex_buffer, .num_vertex_buffers = 1, .vertex_attributes = &vertex_attributes, .num_vertex_attributes = vertex_attributes.len },
        .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
        .rasterizer_state = .{ .fill_mode = c.SDL_GPU_FILLMODE_FILL, .cull_mode = c.SDL_GPU_CULLMODE_NONE, .front_face = c.SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE, .depth_bias_constant_factor = 0, .depth_bias_clamp = 0, .depth_bias_slope_factor = 0, .enable_depth_bias = false, .enable_depth_clip = true, .padding1 = 0, .padding2 = 0 },
        .multisample_state = .{ .sample_count = c.SDL_GPU_SAMPLECOUNT_1, .sample_mask = 0, .enable_mask = false, .padding1 = 0, .padding2 = 0, .padding3 = 0 },
        .depth_stencil_state = .{ .compare_op = c.SDL_GPU_COMPAREOP_NEVER, .back_stencil_state = .{ .fail_op = c.SDL_GPU_STENCILOP_KEEP, .pass_op = c.SDL_GPU_STENCILOP_KEEP, .depth_fail_op = c.SDL_GPU_STENCILOP_KEEP, .compare_op = c.SDL_GPU_COMPAREOP_NEVER }, .front_stencil_state = .{ .fail_op = c.SDL_GPU_STENCILOP_KEEP, .pass_op = c.SDL_GPU_STENCILOP_KEEP, .depth_fail_op = c.SDL_GPU_STENCILOP_KEEP, .compare_op = c.SDL_GPU_COMPAREOP_NEVER }, .compare_mask = 0, .write_mask = 0, .enable_depth_test = false, .enable_depth_write = false, .enable_stencil_test = false, .padding1 = 0, .padding2 = 0, .padding3 = 0 },
        .target_info = .{ .color_target_descriptions = &target, .num_color_targets = 1, .depth_stencil_format = c.SDL_GPU_TEXTUREFORMAT_INVALID, .has_depth_stencil_target = false, .padding1 = 0, .padding2 = 0, .padding3 = 0 },
        .props = 0,
    }) orelse return sdlFail("SDL_CreateGPUGraphicsPipeline");
}

const SpriteShaderStage = enum { vertex, fragment };

fn createSpriteShader(device: *c.SDL_GPUDevice, stage: SpriteShaderStage) !*c.SDL_GPUShader {
    const shader_format = try selectGpuShaderFormat(device);
    const source: []const u8 = if (shader_format == .msl)
        switch (stage) {
            .vertex => sprite_vert_msl,
            .fragment => sprite_frag_msl,
        }
    else switch (stage) {
        .vertex => sprite_vert_spirv,
        .fragment => sprite_frag_spirv,
    };
    const format = if (shader_format == .msl) c.SDL_GPU_SHADERFORMAT_MSL else c.SDL_GPU_SHADERFORMAT_SPIRV;
    const entrypoint: [*:0]const u8 = if (shader_format == .msl) "main0" else "main";
    return c.SDL_CreateGPUShader(device, &.{
        .code_size = source.len,
        .code = source.ptr,
        .entrypoint = entrypoint,
        .format = format,
        .stage = switch (stage) {
            .vertex => c.SDL_GPU_SHADERSTAGE_VERTEX,
            .fragment => c.SDL_GPU_SHADERSTAGE_FRAGMENT,
        },
        .num_samplers = if (stage == .fragment) 1 else 0,
        .num_storage_textures = 0,
        .num_storage_buffers = 0,
        .num_uniform_buffers = 0,
        .props = 0,
    }) orelse return sdlFail("SDL_CreateGPUShader");
}

fn createEffectPipeline(device: *c.SDL_GPUDevice) !*c.SDL_GPUGraphicsPipeline {
    const vertex_shader = try createEffectShader(device, .vertex);
    defer c.SDL_ReleaseGPUShader(device, vertex_shader);
    const fragment_shader = try createEffectShader(device, .fragment);
    defer c.SDL_ReleaseGPUShader(device, fragment_shader);
    const target = c.SDL_GPUColorTargetDescription{ .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM, .blend_state = .{ .src_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE, .dst_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ZERO, .color_blend_op = c.SDL_GPU_BLENDOP_ADD, .src_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE, .dst_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ZERO, .alpha_blend_op = c.SDL_GPU_BLENDOP_ADD, .color_write_mask = 0xF, .enable_blend = false, .enable_color_write_mask = true, .padding1 = 0, .padding2 = 0 } };
    return c.SDL_CreateGPUGraphicsPipeline(device, &.{ .vertex_shader = vertex_shader, .fragment_shader = fragment_shader, .vertex_input_state = .{ .vertex_buffer_descriptions = null, .num_vertex_buffers = 0, .vertex_attributes = null, .num_vertex_attributes = 0 }, .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST, .rasterizer_state = .{ .fill_mode = c.SDL_GPU_FILLMODE_FILL, .cull_mode = c.SDL_GPU_CULLMODE_NONE, .front_face = c.SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE, .depth_bias_constant_factor = 0, .depth_bias_clamp = 0, .depth_bias_slope_factor = 0, .enable_depth_bias = false, .enable_depth_clip = true, .padding1 = 0, .padding2 = 0 }, .multisample_state = .{ .sample_count = c.SDL_GPU_SAMPLECOUNT_1, .sample_mask = 0, .enable_mask = false, .padding1 = 0, .padding2 = 0, .padding3 = 0 }, .depth_stencil_state = .{ .compare_op = c.SDL_GPU_COMPAREOP_NEVER, .back_stencil_state = .{ .fail_op = c.SDL_GPU_STENCILOP_KEEP, .pass_op = c.SDL_GPU_STENCILOP_KEEP, .depth_fail_op = c.SDL_GPU_STENCILOP_KEEP, .compare_op = c.SDL_GPU_COMPAREOP_NEVER }, .front_stencil_state = .{ .fail_op = c.SDL_GPU_STENCILOP_KEEP, .pass_op = c.SDL_GPU_STENCILOP_KEEP, .depth_fail_op = c.SDL_GPU_STENCILOP_KEEP, .compare_op = c.SDL_GPU_COMPAREOP_NEVER }, .compare_mask = 0, .write_mask = 0, .enable_depth_test = false, .enable_depth_write = false, .enable_stencil_test = false, .padding1 = 0, .padding2 = 0, .padding3 = 0 }, .target_info = .{ .color_target_descriptions = &target, .num_color_targets = 1, .depth_stencil_format = c.SDL_GPU_TEXTUREFORMAT_INVALID, .has_depth_stencil_target = false, .padding1 = 0, .padding2 = 0, .padding3 = 0 }, .props = 0 }) orelse return sdlFail("SDL_CreateGPUGraphicsPipeline");
}

fn createEffectShader(device: *c.SDL_GPUDevice, stage: SpriteShaderStage) !*c.SDL_GPUShader {
    const shader_format = try selectGpuShaderFormat(device);
    const source: []const u8 = if (shader_format == .msl) switch (stage) {
        .vertex => effect_vert_msl,
        .fragment => effect_frag_msl,
    } else switch (stage) {
        .vertex => effect_vert_spirv,
        .fragment => effect_frag_spirv,
    };
    const format = if (shader_format == .msl) c.SDL_GPU_SHADERFORMAT_MSL else c.SDL_GPU_SHADERFORMAT_SPIRV;
    const entrypoint: [*:0]const u8 = if (shader_format == .msl) "main0" else "main";
    return c.SDL_CreateGPUShader(device, &.{ .code_size = source.len, .code = source.ptr, .entrypoint = entrypoint, .format = format, .stage = switch (stage) {
        .vertex => c.SDL_GPU_SHADERSTAGE_VERTEX,
        .fragment => c.SDL_GPU_SHADERSTAGE_FRAGMENT,
    }, .num_samplers = if (stage == .fragment) 1 else 0, .num_storage_textures = 0, .num_storage_buffers = 0, .num_uniform_buffers = if (stage == .fragment) 1 else 0, .props = 0 }) orelse return sdlFail("SDL_CreateGPUShader");
}

fn createPrimitivePipeline(device: *c.SDL_GPUDevice, blend: up.BlendMode) !*c.SDL_GPUGraphicsPipeline {
    const vertex_shader = try createPrimitiveShader(device, .vertex);
    defer c.SDL_ReleaseGPUShader(device, vertex_shader);
    const fragment_shader = try createPrimitiveShader(device, .fragment);
    defer c.SDL_ReleaseGPUShader(device, fragment_shader);
    const destination_factor: c.SDL_GPUBlendFactor = switch (blend) {
        .alpha => c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
        .additive => c.SDL_GPU_BLENDFACTOR_ONE,
    };
    const target = c.SDL_GPUColorTargetDescription{
        .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
        .blend_state = .{
            .src_color_blendfactor = c.SDL_GPU_BLENDFACTOR_SRC_ALPHA,
            .dst_color_blendfactor = destination_factor,
            .color_blend_op = c.SDL_GPU_BLENDOP_ADD,
            .src_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
            .dst_alpha_blendfactor = destination_factor,
            .alpha_blend_op = c.SDL_GPU_BLENDOP_ADD,
            .color_write_mask = 0xF,
            .enable_blend = true,
            .enable_color_write_mask = true,
            .padding1 = 0,
            .padding2 = 0,
        },
    };
    const vertex_buffer = c.SDL_GPUVertexBufferDescription{ .slot = 0, .pitch = @sizeOf(up.PrimitiveBatchVertex), .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX, .instance_step_rate = 0 };
    const vertex_attributes = [_]c.SDL_GPUVertexAttribute{
        .{ .location = 0, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = @offsetOf(up.PrimitiveBatchVertex, "x") },
        .{ .location = 1, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4, .offset = @offsetOf(up.PrimitiveBatchVertex, "r") },
    };
    return c.SDL_CreateGPUGraphicsPipeline(device, &.{
        .vertex_shader = vertex_shader,
        .fragment_shader = fragment_shader,
        .vertex_input_state = .{ .vertex_buffer_descriptions = &vertex_buffer, .num_vertex_buffers = 1, .vertex_attributes = &vertex_attributes, .num_vertex_attributes = vertex_attributes.len },
        .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
        .rasterizer_state = .{ .fill_mode = c.SDL_GPU_FILLMODE_FILL, .cull_mode = c.SDL_GPU_CULLMODE_NONE, .front_face = c.SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE, .depth_bias_constant_factor = 0, .depth_bias_clamp = 0, .depth_bias_slope_factor = 0, .enable_depth_bias = false, .enable_depth_clip = true, .padding1 = 0, .padding2 = 0 },
        .multisample_state = .{ .sample_count = c.SDL_GPU_SAMPLECOUNT_1, .sample_mask = 0, .enable_mask = false, .padding1 = 0, .padding2 = 0, .padding3 = 0 },
        .depth_stencil_state = .{ .compare_op = c.SDL_GPU_COMPAREOP_NEVER, .back_stencil_state = .{ .fail_op = c.SDL_GPU_STENCILOP_KEEP, .pass_op = c.SDL_GPU_STENCILOP_KEEP, .depth_fail_op = c.SDL_GPU_STENCILOP_KEEP, .compare_op = c.SDL_GPU_COMPAREOP_NEVER }, .front_stencil_state = .{ .fail_op = c.SDL_GPU_STENCILOP_KEEP, .pass_op = c.SDL_GPU_STENCILOP_KEEP, .depth_fail_op = c.SDL_GPU_STENCILOP_KEEP, .compare_op = c.SDL_GPU_COMPAREOP_NEVER }, .compare_mask = 0, .write_mask = 0, .enable_depth_test = false, .enable_depth_write = false, .enable_stencil_test = false, .padding1 = 0, .padding2 = 0, .padding3 = 0 },
        .target_info = .{ .color_target_descriptions = &target, .num_color_targets = 1, .depth_stencil_format = c.SDL_GPU_TEXTUREFORMAT_INVALID, .has_depth_stencil_target = false, .padding1 = 0, .padding2 = 0, .padding3 = 0 },
        .props = 0,
    }) orelse return sdlFail("SDL_CreateGPUGraphicsPipeline");
}

fn createPrimitiveShader(device: *c.SDL_GPUDevice, stage: SpriteShaderStage) !*c.SDL_GPUShader {
    const shader_format = try selectGpuShaderFormat(device);
    const source: []const u8 = if (shader_format == .msl)
        switch (stage) {
            .vertex => primitive_vert_msl,
            .fragment => primitive_frag_msl,
        }
    else switch (stage) {
        .vertex => primitive_vert_spirv,
        .fragment => primitive_frag_spirv,
    };
    const format = if (shader_format == .msl) c.SDL_GPU_SHADERFORMAT_MSL else c.SDL_GPU_SHADERFORMAT_SPIRV;
    const entrypoint: [*:0]const u8 = if (shader_format == .msl) "main0" else "main";
    return c.SDL_CreateGPUShader(device, &.{
        .code_size = source.len,
        .code = source.ptr,
        .entrypoint = entrypoint,
        .format = format,
        .stage = switch (stage) {
            .vertex => c.SDL_GPU_SHADERSTAGE_VERTEX,
            .fragment => c.SDL_GPU_SHADERSTAGE_FRAGMENT,
        },
        .num_samplers = 0,
        .num_storage_textures = 0,
        .num_storage_buffers = 0,
        .num_uniform_buffers = 0,
        .props = 0,
    }) orelse return sdlFail("SDL_CreateGPUShader");
}

fn pollInput(state: anytype, comptime callbacks: anytype, initialized: bool, ctx: *Context, input: *up.Input, window: *c.SDL_Window, presentation: *up.Presentation, audio_device_changed: *bool, close_requested: *bool, desktop_state: *DesktopState, gpu_recovery: *GpuRecovery) !bool {
    var running = true;
    var event: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&event)) {
        switch (event.type) {
            c.SDL_EVENT_QUIT, c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => {
                close_requested.* = true;
                if (initialized) try callLoopEvent(state, callbacks, ctx, .close_requested);
                running = false;
            },
            c.SDL_EVENT_WINDOW_FOCUS_GAINED => {
                desktop_state.focused = true;
                if (initialized) try callLoopEvent(state, callbacks, ctx, .focus_gained);
            },
            c.SDL_EVENT_WINDOW_FOCUS_LOST => {
                desktop_state.focused = false;
                if (initialized) try callLoopEvent(state, callbacks, ctx, .focus_lost);
            },
            c.SDL_EVENT_WINDOW_MINIMIZED => {
                desktop_state.minimized = true;
                if (initialized) try callLoopEvent(state, callbacks, ctx, .minimized);
            },
            c.SDL_EVENT_WINDOW_RESTORED => {
                desktop_state.minimized = false;
                if (initialized) try callLoopEvent(state, callbacks, ctx, .restored);
            },
            c.SDL_EVENT_RENDER_DEVICE_RESET => {
                gpu_recovery.* = nextGpuRecovery(gpu_recovery.*, .gpu_device_reset);
                if (initialized) try callLoopEvent(state, callbacks, ctx, .gpu_device_reset);
            },
            c.SDL_EVENT_RENDER_DEVICE_LOST => {
                gpu_recovery.* = nextGpuRecovery(gpu_recovery.*, .gpu_device_lost);
                if (initialized) try callLoopEvent(state, callbacks, ctx, .gpu_device_lost);
            },
            c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP => {
                if (event.key.repeat) continue;
                const is_down = event.type == c.SDL_EVENT_KEY_DOWN;
                if (mapKey(event.key.key)) |key| {
                    input.set(key, is_down);
                    if (key == .cancel and is_down) running = false;
                }
            },
            c.SDL_EVENT_WINDOW_RESIZED, c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED => {
                refreshPresentation(window, presentation);
                if (initialized) try callLoopEvent(state, callbacks, ctx, .{ .resized = .{ .framebuffer_size = presentation.framebuffer_size } });
            },
            else => {
                if (audioDeviceChanged(event.type)) {
                    audio_device_changed.* = true;
                    if (initialized) try callLoopEvent(state, callbacks, ctx, .audio_device_changed);
                }
            },
            c.SDL_EVENT_MOUSE_MOTION => setPointerPosition(input, window, presentation, .{ .x = event.motion.x, .y = event.motion.y }),
            c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_EVENT_MOUSE_BUTTON_UP => {
                setPointerPosition(input, window, presentation, .{ .x = event.button.x, .y = event.button.y });
                if (mapPointerButton(event.button.button)) |button| input.setPointerButton(button, event.type == c.SDL_EVENT_MOUSE_BUTTON_DOWN);
            },
            c.SDL_EVENT_MOUSE_WHEEL => input.addPointerWheel(.{ .x = event.wheel.x, .y = event.wheel.y }),
            c.SDL_EVENT_GAMEPAD_ADDED => {
                const id: i32 = @intCast(event.gdevice.which);
                _ = input.addGamepad(id);
                if (initialized) try callLoopEvent(state, callbacks, ctx, .{ .gamepad_connected = id });
            },
            c.SDL_EVENT_GAMEPAD_REMOVED => {
                const id: i32 = @intCast(event.gdevice.which);
                _ = input.removeGamepad(id);
                if (initialized) try callLoopEvent(state, callbacks, ctx, .{ .gamepad_disconnected = id });
            },
            c.SDL_EVENT_GAMEPAD_BUTTON_DOWN, c.SDL_EVENT_GAMEPAD_BUTTON_UP => if (mapGamepadButton(event.gbutton.button)) |button| input.setGamepadButton(@intCast(event.gbutton.which), button, event.type == c.SDL_EVENT_GAMEPAD_BUTTON_DOWN),
            c.SDL_EVENT_GAMEPAD_AXIS_MOTION => if (mapGamepadAxis(event.gaxis.axis)) |axis| input.setGamepadAxis(@intCast(event.gaxis.which), axis, normalizeGamepadAxis(axis, event.gaxis.value), 0.15),
        }
    }
    return running;
}

fn audioDeviceChanged(event_type: c.SDL_EventType) bool {
    return event_type == c.SDL_EVENT_AUDIO_DEVICE_REMOVED or event_type == c.SDL_EVENT_AUDIO_DEVICE_FORMAT_CHANGED;
}

fn mapGamepadButton(button: u8) ?up.GamepadButton {
    return switch (button) {
        c.SDL_GAMEPAD_BUTTON_SOUTH => .south,
        c.SDL_GAMEPAD_BUTTON_EAST => .east,
        c.SDL_GAMEPAD_BUTTON_WEST => .west,
        c.SDL_GAMEPAD_BUTTON_NORTH => .north,
        c.SDL_GAMEPAD_BUTTON_BACK => .back,
        c.SDL_GAMEPAD_BUTTON_START => .start,
        c.SDL_GAMEPAD_BUTTON_LEFT_STICK => .left_stick,
        c.SDL_GAMEPAD_BUTTON_RIGHT_STICK => .right_stick,
        c.SDL_GAMEPAD_BUTTON_LEFT_SHOULDER => .left_shoulder,
        c.SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER => .right_shoulder,
        c.SDL_GAMEPAD_BUTTON_DPAD_UP => .dpad_up,
        c.SDL_GAMEPAD_BUTTON_DPAD_DOWN => .dpad_down,
        c.SDL_GAMEPAD_BUTTON_DPAD_LEFT => .dpad_left,
        c.SDL_GAMEPAD_BUTTON_DPAD_RIGHT => .dpad_right,
        else => null,
    };
}
fn mapGamepadAxis(axis: u8) ?up.GamepadAxis {
    return switch (axis) {
        c.SDL_GAMEPAD_AXIS_LEFTX => .left_x,
        c.SDL_GAMEPAD_AXIS_LEFTY => .left_y,
        c.SDL_GAMEPAD_AXIS_RIGHTX => .right_x,
        c.SDL_GAMEPAD_AXIS_RIGHTY => .right_y,
        c.SDL_GAMEPAD_AXIS_LEFT_TRIGGER => .left_trigger,
        c.SDL_GAMEPAD_AXIS_RIGHT_TRIGGER => .right_trigger,
        else => null,
    };
}
fn normalizeGamepadAxis(axis: up.GamepadAxis, value: i16) f32 {
    const normalized = @as(f32, @floatFromInt(value)) / 32767;
    return switch (axis) {
        .left_trigger, .right_trigger => @max(0, normalized),
        else => normalized,
    };
}

fn framebufferSize(window: *c.SDL_Window) !up.Vec2 {
    var width: c_int = 0;
    var height: c_int = 0;
    if (!c.SDL_GetWindowSizeInPixels(window, &width, &height)) return sdlFail("SDL_GetWindowSizeInPixels");
    if (width <= 0 or height <= 0) return error.InvalidWindowSize;
    return .{ .x = @floatFromInt(width), .y = @floatFromInt(height) };
}

fn refreshPresentation(window: *c.SDL_Window, presentation: *up.Presentation) void {
    const size = framebufferSize(window) catch return;
    updateFramebufferSize(presentation, @intFromFloat(size.x), @intFromFloat(size.y));
}

fn swapchainAvailable(texture: ?*c.SDL_GPUTexture) bool {
    return texture != null;
}

fn updateFramebufferSize(presentation: *up.Presentation, width: u32, height: u32) void {
    if (width == 0 or height == 0) return;
    presentation.framebuffer_size = .{ .x = @floatFromInt(width), .y = @floatFromInt(height) };
}

fn setPointerPosition(input: *up.Input, window: *c.SDL_Window, presentation: *const up.Presentation, window_point: up.Vec2) void {
    var window_width: c_int = 0;
    var window_height: c_int = 0;
    if (!c.SDL_GetWindowSize(window, &window_width, &window_height) or window_width <= 0 or window_height <= 0) return;
    const framebuffer = pointerFramebufferPoint(window_point, .{ .x = @floatFromInt(window_width), .y = @floatFromInt(window_height) }, presentation);
    input.setPointerPosition(window_point, framebuffer, presentation.framebufferToCanvas(framebuffer));
}

fn pointerFramebufferPoint(window_point: up.Vec2, window_size: up.Vec2, presentation: *const up.Presentation) up.Vec2 {
    return .{ .x = window_point.x * presentation.framebuffer_size.x / window_size.x, .y = window_point.y * presentation.framebuffer_size.y / window_size.y };
}

fn mapPointerButton(button: u8) ?up.PointerButton {
    return switch (button) {
        c.SDL_BUTTON_LEFT => .left,
        c.SDL_BUTTON_MIDDLE => .middle,
        c.SDL_BUTTON_RIGHT => .right,
        c.SDL_BUTTON_X1 => .back,
        c.SDL_BUTTON_X2 => .forward,
        else => null,
    };
}

fn mapKey(key: c.SDL_Keycode) ?up.Key {
    return switch (key) {
        c.SDLK_UP => .up,
        c.SDLK_DOWN => .down,
        c.SDLK_LEFT => .left,
        c.SDLK_RIGHT => .right,
        c.SDLK_SPACE => .action,
        c.SDLK_ESCAPE => .cancel,
        c.SDLK_RETURN => .start,
        c.SDLK_TAB => .select,
        c.SDLK_F3 => .debug,
        c.SDLK_F12 => .screenshot,
        else => null,
    };
}

fn canvasFromRgba(allocator: std.mem.Allocator, width: u32, height: u32, rgba: []const u8) !up.Canvas {
    const byte_len: usize = try checkedByteLen(width, height);
    if (rgba.len != byte_len) return error.InvalidCapturePixels;
    var canvas = try up.Canvas.init(allocator, width, height);
    errdefer canvas.deinit();
    for (canvas.pixels, 0..) |*pixel, index| {
        const offset = index * 4;
        pixel.* = .{ .r = rgba[offset], .g = rgba[offset + 1], .b = rgba[offset + 2], .a = rgba[offset + 3] };
    }
    return canvas;
}

fn renderConformanceCanvas(allocator: std.mem.Allocator, width: u32, height: u32) !up.Canvas {
    if (width < 3 or height < 2) return error.InvalidConformanceCanvas;
    var canvas = try up.Canvas.init(allocator, width, height);
    errdefer canvas.deinit();
    var commands = up.RenderCommandBuffer.init(allocator);
    defer commands.deinit();
    try commands.append(.{ .clear = up.Color.rgba(19, 37, 61, 255) });
    try commands.append(.{ .rect = .{ .x = 0, .y = 0, .w = 1, .h = 1, .color = up.Color.rgba(1, 2, 3, 255) } });
    try commands.append(.{ .rect = .{ .x = 1, .y = 0, .w = 1, .h = 1, .color = up.Color.rgba(5, 6, 7, 255) } });
    try commands.append(.{ .rect = .{ .x = @intCast(width - 1), .y = @intCast(height - 1), .w = 1, .h = 1, .color = up.Color.rgba(9, 10, 11, 255) } });
    try renderCommands(allocator, &canvas, commands.commands.items);
    return canvas;
}

fn expectConformanceGolden(canvas: *const up.Canvas) !void {
    try std.testing.expect(canvas.width >= 3 and canvas.height >= 2);
    const last_x = std.math.cast(i32, canvas.width - 1) orelse return error.InvalidConformanceCanvas;
    const last_y = std.math.cast(i32, canvas.height - 1) orelse return error.InvalidConformanceCanvas;
    try std.testing.expectEqual(up.Color.rgba(1, 2, 3, 255), canvas.get(0, 0).?);
    try std.testing.expectEqual(up.Color.rgba(5, 6, 7, 255), canvas.get(1, 0).?);
    try std.testing.expectEqual(up.Color.rgba(19, 37, 61, 255), canvas.get(2, 1).?);
    try std.testing.expectEqual(up.Color.rgba(9, 10, 11, 255), canvas.get(last_x, last_y).?);
}

fn checkedByteLen(width: u32, height: u32) !u32 {
    const pixels = std.math.mul(u32, width, height) catch return error.CanvasTooLarge;
    return std.math.mul(u32, pixels, 4) catch error.CanvasTooLarge;
}

fn scaledInt(value: u32, scale: u32) !c_int {
    const scaled = std.math.mul(u32, value, scale) catch return error.InvalidConfig;
    return std.math.cast(c_int, scaled) orelse error.InvalidConfig;
}

fn configFromArgs(allocator: std.mem.Allocator, config: Config) !Config {
    var parsed = config;
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--frames")) {
            const value = args.next() orelse return error.MissingFrameCount;
            parsed.max_frames = try std.fmt.parseInt(u32, value, 10);
        }
    }
    return parsed;
}

fn ticksToSeconds(ns: u64) f32 {
    return @as(f32, @floatFromInt(ns)) / 1_000_000_000.0;
}

fn requiredGpuShaderFormats() c.SDL_GPUShaderFormat {
    return @intCast(GpuCapabilities.required_shader_formats);
}

fn gpuCapabilities(device: *c.SDL_GPUDevice) GpuCapabilities {
    return .{ .shader_formats = @intCast(c.SDL_GetGPUShaderFormats(device)) };
}

fn gpuDriverName(device: *c.SDL_GPUDevice) []const u8 {
    const raw = c.SDL_GetGPUDeviceDriver(device) orelse return "unknown";
    return std.mem.span(raw);
}

fn printGpuDrivers() void {
    const count = c.SDL_GetNumGPUDrivers();
    var index: c_int = 0;
    while (index < count) : (index += 1) {
        if (index != 0) std.debug.print(",", .{});
        const driver = c.SDL_GetGPUDriver(index) orelse {
            std.debug.print("unknown", .{});
            continue;
        };
        std.debug.print("{s}", .{std.mem.span(driver)});
    }
    if (count == 0) std.debug.print("none", .{});
}

fn rendererConformanceEnabled() bool {
    return std.process.hasEnvVarConstant("UP_RENDERER_CONFORMANCE") or std.process.hasEnvVarConstant("UP_GPU_CAPTURE_TEST");
}

fn rendererConformanceRequiresGpu() bool {
    return std.process.hasEnvVarConstant("UP_RENDERER_CONFORMANCE_REQUIRE_GPU");
}

fn printRendererConformanceUnavailable() void {
    std.debug.print("renderer conformance unavailable: platform={s} required_shader_formats=0x{x} drivers=[", .{ @tagName(builtin.os.tag), GpuCapabilities.required_shader_formats });
    printGpuDrivers();
    std.debug.print("] sdl_error={s}\n", .{c.SDL_GetError()});
}

fn selectGpuShaderFormat(device: *c.SDL_GPUDevice) error{UnsupportedGpuShaderFormat}!GpuShaderFormat {
    return gpuCapabilities(device).requireShaderFormat() catch {
        const capabilities = gpuCapabilities(device);
        std.debug.print("SDL GPU capability failure: platform={s} driver={s} shader_formats=0x{x} required_shader_formats=0x{x}\n", .{ @tagName(builtin.os.tag), gpuDriverName(device), capabilities.shader_formats, GpuCapabilities.required_shader_formats });
        return error.UnsupportedGpuShaderFormat;
    };
}

fn formatGpuDiagnostics(buffer: []u8, operation: []const u8, driver: []const u8, capabilities: GpuCapabilities) ![]const u8 {
    return std.fmt.bufPrint(buffer, "SDL GPU failure: operation={s} platform={s} driver={s} shader_formats=0x{x} required_shader_formats=0x{x}", .{ operation, @tagName(builtin.os.tag), driver, capabilities.shader_formats, GpuCapabilities.required_shader_formats });
}

fn sdlRendererFail(comptime label: []const u8) error{SdlError} {
    std.debug.print("SDL renderer failure: operation={s} platform={s} required_shader_formats=0x{x} drivers=[", .{ label, @tagName(builtin.os.tag), GpuCapabilities.required_shader_formats });
    printGpuDrivers();
    std.debug.print("] sdl_error={s}\n", .{c.SDL_GetError()});
    return error.SdlError;
}

fn sdlGpuFail(device: *c.SDL_GPUDevice, comptime label: []const u8) error{SdlError} {
    const capabilities = gpuCapabilities(device);
    var buffer: [256]u8 = undefined;
    const diagnostic = formatGpuDiagnostics(&buffer, label, gpuDriverName(device), capabilities) catch unreachable;
    std.debug.print("{s} sdl_error={s}\n", .{ diagnostic, c.SDL_GetError() });
    return error.SdlError;
}

fn sdlFail(comptime label: []const u8) error{SdlError} {
    std.debug.print("SDL failure: operation={s} platform={s} required_shader_formats=0x{x} drivers=[", .{ label, @tagName(builtin.os.tag), GpuCapabilities.required_shader_formats });
    printGpuDrivers();
    std.debug.print("] sdl_error={s}\n", .{c.SDL_GetError()});
    return error.SdlError;
}

fn audioFail(strict: bool, comptime label: []const u8) error{SdlError}!?AudioOutput {
    std.debug.print("audio muted: {s}: {s}\n", .{ label, c.SDL_GetError() });
    if (strict) return error.SdlError;
    return null;
}
