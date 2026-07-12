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

test "SDL3 headers are available" {
    _ = c.SDL_INIT_VIDEO;
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
    developer_tools: bool = builtin.mode == .Debug,
    clear_color: up.Color = up.Color.black,
    max_frames: ?u32 = null,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    canvas: *up.Canvas,
    input: *up.Input,
    assets: *up.AssetStore,
    audio: *up.AudioMixer,
    app_data_path: []const u8,
    presentation: *const up.Presentation,
    sprite_batch: *up.SpriteBatch,
    commands: *up.RenderCommandBuffer,
    dt: f32,
    frame: u64,

    pub fn clear(self: *Context, color: up.Color) void {
        self.canvas.clear(color);
    }

    pub fn camera(self: *Context, target_camera: *const up.Camera2D) up.CameraCanvas {
        return .init(self.canvas, target_camera);
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

    pub fn image(self: *Context, handle: up.ImageHandle, x: i32, y: i32) void {
        const source_image = self.assets.latestImagePtr(handle) catch @panic("invalid image handle");
        appendImageQuad(self.sprite_batch, self.canvas.width, self.canvas.height, source_image, x, y) catch self.canvas.drawImage(source_image.*, x, y);
    }

    pub fn sprite(self: *Context, atlas_handle: up.AtlasHandle, frame: up.AtlasFrameHandle, x: i32, y: i32, options: up.DrawSpriteOptions) void {
        const source_atlas = self.assets.latestAtlasPtr(atlas_handle) catch @panic("invalid atlas handle");
        appendAtlasQuad(self.sprite_batch, self.canvas.width, self.canvas.height, source_atlas, frame, x, y, options) catch self.canvas.drawAtlasFrame(source_atlas.*, frame, x, y, options);
    }

    pub fn loadPng(self: *Context, path: []const u8) !up.ImageHandle {
        return self.assets.loadPng(path);
    }

    pub fn loadImage(self: *Context, path: []const u8) !up.ImageHandle {
        return self.assets.loadImage(path);
    }

    pub fn loadAtlas(self: *Context, path: []const u8) !up.AtlasHandle {
        return self.assets.loadAtlas(path);
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
        return self.assets.loadTileMap(path);
    }

    pub fn loadTileMapWithOptions(self: *Context, path: []const u8, options: up.TileMapAssetOptions) !up.TileMapHandle {
        return self.assets.loadTileMapWithOptions(path, options);
    }

    pub fn tileMap(self: *Context, handle: up.TileMapHandle) *const up.TileMap {
        return self.assets.tileMapPtr(handle);
    }

    pub fn drawTileMap(self: *Context, handle: up.TileMapHandle, target_camera: *const up.Camera2D, time: f32) void {
        self.assets.drawTileMap(handle, target_camera, self.canvas, time);
    }

    pub fn loadText(self: *Context, path: []const u8) !up.TextHandle {
        return self.assets.loadText(path);
    }

    pub fn textAsset(self: *Context, handle: up.TextHandle) []const u8 {
        return self.assets.latestText(handle) catch @panic("invalid text handle");
    }

    pub fn down(self: *Context, key: up.Key) bool {
        return self.input.isDown(key);
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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) @panic("game allocation leak");

    const allocator = gpa.allocator();
    const parsed_config = try configFromArgs(allocator, config);
    try playWithAllocator(allocator, parsed_config, Game);
}

fn playWithAllocator(allocator: std.mem.Allocator, config: Config, comptime Game: type) !void {
    if (config.width == 0 or config.height == 0 or config.scale == 0) return error.InvalidConfig;
    if (!c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_EVENTS)) return sdlFail("SDL_Init");
    defer c.SDL_Quit();

    const window_w = try scaledInt(config.width, config.scale);
    const window_h = try scaledInt(config.height, config.scale);
    const window_flags: c.SDL_WindowFlags = if (config.resizable) c.SDL_WINDOW_RESIZABLE else 0;
    const window = c.SDL_CreateWindow(config.title.ptr, window_w, window_h, window_flags) orelse return sdlFail("SDL_CreateWindow");
    defer c.SDL_DestroyWindow(window);

    const shader_formats = c.SDL_GPU_SHADERFORMAT_MSL | c.SDL_GPU_SHADERFORMAT_SPIRV;
    const device = c.SDL_CreateGPUDevice(shader_formats, true, null) orelse return sdlFail("SDL_CreateGPUDevice");
    defer c.SDL_DestroyGPUDevice(device);

    if (!c.SDL_ClaimWindowForGPUDevice(device, window)) return sdlFail("SDL_ClaimWindowForGPUDevice");
    defer c.SDL_ReleaseWindowFromGPUDevice(device, window);

    if (!c.SDL_SetGPUSwapchainParameters(device, window, c.SDL_GPU_SWAPCHAINCOMPOSITION_SDR, c.SDL_GPU_PRESENTMODE_VSYNC)) {
        return sdlFail("SDL_SetGPUSwapchainParameters");
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

    var audio = try up.AudioMixer.init(allocator, .{ .sample_rate = config.audio_sample_rate });
    defer audio.deinit();

    var audio_output = try AudioOutput.init(allocator, config.audio_sample_rate, config.audio_buffer_frames, config.strict_audio);
    defer if (audio_output) |*output| output.deinit(allocator);

    var input = up.Input{};
    var presentation = up.Presentation.init(.{ .x = @floatFromInt(config.width), .y = @floatFromInt(config.height) }, try framebufferSize(window), config.presentation_mode);
    var clock = up.StepClock.init(config.fixed_hz);
    const data_path = try appDataPath(allocator, config.organization, config.application);
    defer allocator.free(data_path);
    var dev = try DeveloperTools.init(allocator, config.developer_tools, data_path);
    defer dev.deinit();
    var presenter = try Presenter.init(device, config.width, config.height);
    defer presenter.deinit(device);

    var ctx = Context{ .allocator = allocator, .canvas = &canvas, .input = &input, .assets = &assets, .audio = &audio, .app_data_path = data_path, .presentation = &presentation, .sprite_batch = &sprite_batch, .commands = &commands, .dt = 0, .frame = 0 };
    var failure: ?Failure = null;
    var game: ?Game = initGame(Game, &ctx) catch |err| blk: {
        dev.failure("init", err);
        failure = .{ .phase = "init", .err = err };
        break :blk null;
    };
    defer if (game) |*value| deinitGame(Game, value, &ctx);

    var running = true;
    var last_ticks = c.SDL_GetTicksNS();

    while (running) {
        input.beginFrame();
        sprite_batch.clear();
        commands.commands.clearRetainingCapacity();
        refreshPresentation(window, &presentation);
        var audio_device_changed = false;
        running = pollInput(&input, window, &presentation, &audio_device_changed);
        if (audio_device_changed) {
            if (audio_output) |*output| output.deinit(allocator);
            audio_output = try AudioOutput.init(allocator, config.audio_sample_rate, config.audio_buffer_frames, config.strict_audio);
        }
        if (input.wasPressed(.debug)) dev.toggleOverlay();

        if (failure) |current| {
            drawFailure(&canvas, current);
            try presenter.present(device, window, canvas, &sprite_batch, commands.commands.items, &presentation);
            running = advanceFrame(&ctx.frame, config.max_frames) and running;
            continue;
        }

        const reload_events = assets.reloadChanged() catch |err| {
            dev.failure("asset reload", err);
            failure = .{ .phase = "asset reload", .err = err };
            continue;
        };

        const now = c.SDL_GetTicksNS();
        const dt = ticksToSeconds(now - last_ticks);
        last_ticks = now;

        const steps = clock.push(dt);
        var step: u32 = 0;
        while (step < steps) : (step += 1) {
            ctx.dt = clock.step_seconds;
            if (game) |*value| {
                callUpdate(Game, value, &ctx) catch |err| {
                    dev.failure("update", err);
                    failure = .{ .phase = "update", .err = err };
                    break;
                };
            }
        }
        if (failure != null) continue;

        canvas.clear(config.clear_color);
        ctx.dt = dt;
        if (game) |*value| {
            callDraw(Game, value, &ctx) catch |err| {
                dev.failure("draw", err);
                failure = .{ .phase = "draw", .err = err };
                continue;
            };
        }
        drawReloadOverlay(&canvas, reload_events);
        dev.drawOverlay(&canvas, dt, ctx.frame);
        if (input.wasPressed(.screenshot)) dev.writeScreenshot(canvas, ctx.frame);
        if (audio_output) |*output| try output.queue(&audio);
        try presenter.present(device, window, canvas, &sprite_batch, commands.commands.items, &presentation);

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
        else => @compileError("game callbacks must return void or !void"),
    }
}

test "lifecycle accepts optional callbacks" {
    const DrawOnly = struct {
        pub fn draw(_: *@This(), _: *Context) void {}
    };
    const Full = struct {
        pub fn init(_: *Context) @This() {
            return .{};
        }
        pub fn deinit(_: *@This(), _: *Context) void {}
        pub fn update(_: *@This(), _: *Context) !void {}
        pub fn draw(_: *@This(), _: *Context) !void {}
    };

    var ctx: Context = undefined;
    var draw_only = try initGame(DrawOnly, &ctx);
    try callUpdate(DrawOnly, &draw_only, &ctx);
    try callDraw(DrawOnly, &draw_only, &ctx);

    var full = try initGame(Full, &ctx);
    try callUpdate(Full, &full, &ctx);
    try callDraw(Full, &full, &ctx);
    deinitGame(Full, &full, &ctx);
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
    phase: []const u8,
    err: anyerror,
};

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
        std.debug.print("unpolished-peas app data: {s}\n", .{app_data_path});
        return tools;
    }

    fn deinit(self: *DeveloperTools) void {
        if (self.log_file) |file| file.close();
        self.* = undefined;
    }

    fn toggleOverlay(self: *DeveloperTools) void {
        if (self.enabled) self.overlay = !self.overlay;
    }

    fn failure(self: *DeveloperTools, phase: []const u8, err: anyerror) void {
        var buffer: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buffer, "unpolished-peas {s} failed: {s}\n", .{ phase, @errorName(err) }) catch return;
        std.debug.print("{s}", .{line});
        self.note(line);
    }

    fn writeScreenshot(self: *DeveloperTools, canvas: up.Canvas, frame: u64) void {
        if (!self.enabled) return;
        const path = std.fmt.allocPrint(self.allocator, "{s}screenshot-{d}-{d}.ppm", .{ self.app_data_path, c.SDL_GetTicksNS(), frame }) catch |err| {
            self.failure("screenshot path", err);
            return;
        };
        defer self.allocator.free(path);
        canvas.writePpmFile(path) catch |err| {
            self.failure("screenshot", err);
            return;
        };
        var buffer: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&buffer, "unpolished-peas screenshot: {s}\n", .{path}) catch return;
        std.debug.print("{s}", .{line});
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

fn drawFailure(canvas: *up.Canvas, failure: Failure) void {
    canvas.clear(up.Color.rgb(41, 18, 24));
    canvas.fillRect(2, 2, @intCast(canvas.width -| 4), @intCast(canvas.height -| 4), up.Color.rgb(88, 31, 40));
    canvas.drawText("ERROR", 6, 6, up.Color.rgb(255, 225, 225));
    canvas.drawText(failure.phase, 6, 18, up.Color.rgb(255, 198, 74));
    canvas.drawText(@errorName(failure.err), 6, 30, up.Color.rgb(255, 225, 225));
    canvas.drawText("ESC TO QUIT", 6, 48, up.Color.rgb(225, 232, 240));
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
};

const Presenter = struct {
    texture: *c.SDL_GPUTexture,
    transfer: *c.SDL_GPUTransferBuffer,
    width: u32,
    height: u32,
    byte_len: u32,
    resources: up.GpuResources,
    texture_handle: up.TextureHandle,
    sprite_textures: std.ArrayList(SpriteTexture) = .empty,
    sprite_pipeline: ?*c.SDL_GPUGraphicsPipeline = null,
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
        const texture = c.SDL_CreateGPUTexture(device, &.{
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
        errdefer c.SDL_ReleaseGPUTexture(device, texture);

        const transfer = c.SDL_CreateGPUTransferBuffer(device, &.{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = byte_len,
            .props = 0,
        }) orelse return sdlFail("SDL_CreateGPUTransferBuffer");
        errdefer c.SDL_ReleaseGPUTransferBuffer(device, transfer);

        var resources = up.GpuResources.init(std.heap.page_allocator);
        const texture_handle = try resources.createTexture();
        var presenter = Presenter{ .texture = texture, .transfer = transfer, .width = width, .height = height, .byte_len = byte_len, .resources = resources, .texture_handle = texture_handle, .primitive_batch = up.PrimitiveBatch.init(std.heap.page_allocator) };
        errdefer presenter.deinit(device);
        presenter.nearest_sampler = try createSpriteSampler(device, .nearest);
        presenter.linear_sampler = try createSpriteSampler(device, .linear);
        presenter.sprite_pipeline = try createSpritePipeline(device);
        presenter.primitive_alpha_pipeline = try createPrimitivePipeline(device, .alpha);
        presenter.primitive_additive_pipeline = try createPrimitivePipeline(device, .additive);
        return presenter;
    }

    fn deinit(self: *Presenter, device: *c.SDL_GPUDevice) void {
        if (self.sprite_pipeline) |pipeline| c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);
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
        c.SDL_ReleaseGPUTexture(device, self.texture);
        self.resources.destroyTexture(self.texture_handle) catch unreachable;
        self.resources.deinit();
        self.* = undefined;
    }

    fn present(self: *Presenter, device: *c.SDL_GPUDevice, window: *c.SDL_Window, canvas: up.Canvas, sprites: *up.SpriteBatch, commands: []const up.RenderCommand, presentation: *up.Presentation) !void {
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
            .texture = self.texture,
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

        if (self.primitive_batch.vertices.items.len != 0) try self.renderPrimitives(command);
        if (sprites.vertices.items.len != 0) try self.renderSprites(command, sprites);

        var swapchain: ?*c.SDL_GPUTexture = null;
        var swap_w: u32 = 0;
        var swap_h: u32 = 0;
        if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(command, window, &swapchain, &swap_w, &swap_h)) {
            return sdlFail("SDL_WaitAndAcquireGPUSwapchainTexture");
        }
        acquired_swapchain = true;
        if (swapchainAvailable(swapchain)) {
            const target = swapchain.?;
            updateFramebufferSize(presentation, swap_w, swap_h);
            const destination = presentation.destination();
            c.SDL_BlitGPUTexture(command, &.{
                .source = .{
                    .texture = self.texture,
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

        if (!c.SDL_SubmitGPUCommandBuffer(command)) return sdlFail("SDL_SubmitGPUCommandBuffer");
        self.reclaimUnusedSprites(device);
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
            .texture = self.texture,
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
            .texture = self.texture,
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
    const formats = c.SDL_GetGPUShaderFormats(device);
    const source: []const u8 = if ((formats & c.SDL_GPU_SHADERFORMAT_MSL) != 0)
        switch (stage) {
            .vertex => sprite_vert_msl,
            .fragment => sprite_frag_msl,
        }
    else if ((formats & c.SDL_GPU_SHADERFORMAT_SPIRV) != 0)
        switch (stage) {
            .vertex => sprite_vert_spirv,
            .fragment => sprite_frag_spirv,
        }
    else
        return error.UnsupportedGpuShaderFormat;
    const format = if ((formats & c.SDL_GPU_SHADERFORMAT_MSL) != 0) c.SDL_GPU_SHADERFORMAT_MSL else c.SDL_GPU_SHADERFORMAT_SPIRV;
    const entrypoint: [*:0]const u8 = if (format == c.SDL_GPU_SHADERFORMAT_MSL) "main0" else "main";
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
    const formats = c.SDL_GetGPUShaderFormats(device);
    const source: []const u8 = if ((formats & c.SDL_GPU_SHADERFORMAT_MSL) != 0)
        switch (stage) {
            .vertex => primitive_vert_msl,
            .fragment => primitive_frag_msl,
        }
    else if ((formats & c.SDL_GPU_SHADERFORMAT_SPIRV) != 0)
        switch (stage) {
            .vertex => primitive_vert_spirv,
            .fragment => primitive_frag_spirv,
        }
    else
        return error.UnsupportedGpuShaderFormat;
    const format = if ((formats & c.SDL_GPU_SHADERFORMAT_MSL) != 0) c.SDL_GPU_SHADERFORMAT_MSL else c.SDL_GPU_SHADERFORMAT_SPIRV;
    const entrypoint: [*:0]const u8 = if (format == c.SDL_GPU_SHADERFORMAT_MSL) "main0" else "main";
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

fn pollInput(input: *up.Input, window: *c.SDL_Window, presentation: *up.Presentation, audio_device_changed: *bool) bool {
    var running = true;
    var event: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&event)) {
        switch (event.type) {
            c.SDL_EVENT_QUIT, c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => running = false,
            c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP => {
                if (event.key.repeat) continue;
                const is_down = event.type == c.SDL_EVENT_KEY_DOWN;
                if (mapKey(event.key.key)) |key| {
                    input.set(key, is_down);
                    if (key == .cancel and is_down) running = false;
                }
            },
            c.SDL_EVENT_WINDOW_RESIZED, c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED => refreshPresentation(window, presentation),
            else => {
                if (audioDeviceChanged(event.type)) audio_device_changed.* = true;
            },
            c.SDL_EVENT_MOUSE_MOTION => setPointerPosition(input, window, presentation, .{ .x = event.motion.x, .y = event.motion.y }),
            c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_EVENT_MOUSE_BUTTON_UP => {
                setPointerPosition(input, window, presentation, .{ .x = event.button.x, .y = event.button.y });
                if (mapPointerButton(event.button.button)) |button| input.setPointerButton(button, event.type == c.SDL_EVENT_MOUSE_BUTTON_DOWN);
            },
            c.SDL_EVENT_MOUSE_WHEEL => input.addPointerWheel(.{ .x = event.wheel.x, .y = event.wheel.y }),
            c.SDL_EVENT_GAMEPAD_ADDED => _ = input.addGamepad(@intCast(event.gdevice.which)),
            c.SDL_EVENT_GAMEPAD_REMOVED => _ = input.removeGamepad(@intCast(event.gdevice.which)),
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
    const framebuffer = up.Vec2{
        .x = window_point.x * presentation.framebuffer_size.x / @as(f32, @floatFromInt(window_width)),
        .y = window_point.y * presentation.framebuffer_size.y / @as(f32, @floatFromInt(window_height)),
    };
    input.setPointerPosition(window_point, framebuffer, presentation.framebufferToCanvas(framebuffer));
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

fn sdlFail(comptime label: []const u8) error{SdlError} {
    std.debug.print("{s}: {s}\n", .{ label, c.SDL_GetError() });
    return error.SdlError;
}

fn audioFail(strict: bool, comptime label: []const u8) error{SdlError}!?AudioOutput {
    std.debug.print("audio muted: {s}: {s}\n", .{ label, c.SDL_GetError() });
    if (strict) return error.SdlError;
    return null;
}
