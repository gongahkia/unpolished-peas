const std = @import("std");
const builtin = @import("builtin");
const up = @import("unpolished-peas");
const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

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
        self.canvas.fillRect(x, y, w, h, color);
    }

    pub fn circle(self: *Context, x: i32, y: i32, radius: i32, color: up.Color) void {
        self.canvas.fillCircle(x, y, radius, color);
    }

    pub fn line(self: *Context, x0: i32, y0: i32, x1: i32, y1: i32, color: up.Color) void {
        self.canvas.line(x0, y0, x1, y1, color);
    }

    pub fn text(self: *Context, value: []const u8, x: i32, y: i32, color: up.Color) void {
        self.canvas.drawText(value, x, y, color);
    }

    pub fn image(self: *Context, handle: up.ImageHandle, x: i32, y: i32) void {
        self.canvas.drawImage(self.assets.image(handle), x, y);
    }

    pub fn sprite(self: *Context, atlas_handle: up.AtlasHandle, frame: up.AtlasFrameHandle, x: i32, y: i32, options: up.DrawSpriteOptions) void {
        self.canvas.drawAtlasFrame(self.assets.atlas(atlas_handle), frame, x, y, options);
    }

    pub fn loadPng(self: *Context, path: []const u8) !up.ImageHandle {
        return self.assets.loadPng(path);
    }

    pub fn loadAtlas(self: *Context, path: []const u8) !up.AtlasHandle {
        return self.assets.loadAtlas(path);
    }

    pub fn atlasFrame(self: *Context, atlas_handle: up.AtlasHandle, name: []const u8) ?up.AtlasFrameHandle {
        return self.assets.atlas(atlas_handle).findFrame(name);
    }

    pub fn atlas(self: *Context, atlas_handle: up.AtlasHandle) *const up.Atlas {
        return self.assets.atlasPtr(atlas_handle);
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
        return self.assets.text(handle);
    }

    pub fn down(self: *Context, key: up.Key) bool {
        return self.input.isDown(key);
    }

    pub fn appDataPath(self: *Context) []const u8 {
        return self.app_data_path;
    }
};

pub fn appDataPath(allocator: std.mem.Allocator, organization: [:0]const u8, application: [:0]const u8) ![]u8 {
    const raw = c.SDL_GetPrefPath(organization.ptr, application.ptr) orelse return sdlFail("SDL_GetPrefPath");
    defer c.SDL_free(raw);
    return allocator.dupe(u8, std.mem.span(raw));
}

pub fn play(config: Config, comptime Game: type) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

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

    const shader_formats = c.SDL_GPU_SHADERFORMAT_MSL | c.SDL_GPU_SHADERFORMAT_SPIRV | c.SDL_GPU_SHADERFORMAT_DXIL;
    const device = c.SDL_CreateGPUDevice(shader_formats, true, null) orelse return sdlFail("SDL_CreateGPUDevice");
    defer c.SDL_DestroyGPUDevice(device);

    if (!c.SDL_ClaimWindowForGPUDevice(device, window)) return sdlFail("SDL_ClaimWindowForGPUDevice");
    defer c.SDL_ReleaseWindowFromGPUDevice(device, window);

    if (!c.SDL_SetGPUSwapchainParameters(device, window, c.SDL_GPU_SWAPCHAINCOMPOSITION_SDR, c.SDL_GPU_PRESENTMODE_VSYNC)) {
        return sdlFail("SDL_SetGPUSwapchainParameters");
    }

    var canvas = try up.Canvas.init(allocator, config.width, config.height);
    defer canvas.deinit();

    var assets = up.AssetStore.init(allocator, std.fs.cwd());
    defer assets.deinit();

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

    var ctx = Context{ .allocator = allocator, .canvas = &canvas, .input = &input, .assets = &assets, .audio = &audio, .app_data_path = data_path, .presentation = &presentation, .dt = 0, .frame = 0 };
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
        refreshPresentation(window, &presentation);
        running = pollInput(&input, window, &presentation);
        if (input.wasPressed(.debug)) dev.toggleOverlay();

        if (failure) |current| {
            drawFailure(&canvas, current);
            try presenter.present(device, window, canvas, &presentation);
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
        try presenter.present(device, window, canvas, &presentation);

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

    fn init(device: *c.SDL_GPUDevice, width: u32, height: u32) !Presenter {
        const byte_len = try checkedByteLen(width, height);
        const texture = c.SDL_CreateGPUTexture(device, &.{
            .type = c.SDL_GPU_TEXTURETYPE_2D,
            .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
            .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
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
        return .{ .texture = texture, .transfer = transfer, .width = width, .height = height, .byte_len = byte_len, .resources = resources, .texture_handle = texture_handle };
    }

    fn deinit(self: *Presenter, device: *c.SDL_GPUDevice) void {
        c.SDL_ReleaseGPUTransferBuffer(device, self.transfer);
        c.SDL_ReleaseGPUTexture(device, self.texture);
        self.resources.destroyTexture(self.texture_handle) catch unreachable;
        self.resources.deinit();
        self.* = undefined;
    }

    fn present(self: *Presenter, device: *c.SDL_GPUDevice, window: *c.SDL_Window, canvas: up.Canvas, presentation: *up.Presentation) !void {
        try self.copyCanvas(device, canvas);

        const command = c.SDL_AcquireGPUCommandBuffer(device) orelse return sdlFail("SDL_AcquireGPUCommandBuffer");
        var acquired_swapchain = false;
        errdefer {
            if (!acquired_swapchain) _ = c.SDL_CancelGPUCommandBuffer(command);
        }

        const copy_pass = c.SDL_BeginGPUCopyPass(command) orelse return sdlFail("SDL_BeginGPUCopyPass");
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
        c.SDL_EndGPUCopyPass(copy_pass);

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
};

fn pollInput(input: *up.Input, window: *c.SDL_Window, presentation: *up.Presentation) bool {
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
            c.SDL_EVENT_MOUSE_MOTION => setPointerPosition(input, window, presentation, .{ .x = event.motion.x, .y = event.motion.y }),
            c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_EVENT_MOUSE_BUTTON_UP => {
                setPointerPosition(input, window, presentation, .{ .x = event.button.x, .y = event.button.y });
                if (mapPointerButton(event.button.button)) |button| input.setPointerButton(button, event.type == c.SDL_EVENT_MOUSE_BUTTON_DOWN);
            },
            c.SDL_EVENT_MOUSE_WHEEL => input.addPointerWheel(.{ .x = event.wheel.x, .y = event.wheel.y }),
            else => {},
        }
    }
    return running;
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
