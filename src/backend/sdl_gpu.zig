const std = @import("std");
const up = @import("unpolished");
const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

pub const Config = struct {
    title: [:0]const u8 = "unpolished",
    width: u32 = 320,
    height: u32 = 180,
    scale: u32 = 3,
    fixed_hz: u32 = 60,
    clear_color: up.Color = up.Color.black,
    max_frames: ?u32 = null,
};

pub const Frame = struct {
    canvas: *up.Canvas,
    input: *up.Input,
    assets: *up.AssetStore,
    dt: f32,
};

pub const Context = struct {
    canvas: *up.Canvas,
    input: *up.Input,
    assets: *up.AssetStore,
    dt: f32,
    frame: u64,

    pub fn clear(self: *Context, color: up.Color) void {
        self.canvas.clear(color);
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

    pub fn loadPng(self: *Context, path: []const u8) !up.ImageHandle {
        return self.assets.loadPng(path);
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
};

pub fn play(config: Config, comptime Game: type) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();
    const parsed_config = try configFromArgs(allocator, config);
    try playWithAllocator(allocator, parsed_config, Game);
}

pub fn run(allocator: std.mem.Allocator, config: Config, comptime Game: type) !void {
    if (config.width == 0 or config.height == 0 or config.scale == 0) return error.InvalidConfig;
    if (!c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_EVENTS)) return sdlFail("SDL_Init");
    defer c.SDL_Quit();

    const window_w = try scaledInt(config.width, config.scale);
    const window_h = try scaledInt(config.height, config.scale);
    const window = c.SDL_CreateWindow(config.title.ptr, window_w, window_h, 0) orelse return sdlFail("SDL_CreateWindow");
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

    var input = up.Input{};
    var clock = up.StepClock.init(config.fixed_hz);
    var game = try Game.init(allocator);
    defer game.deinit();

    var presenter = try Presenter.init(device, config.width, config.height);
    defer presenter.deinit(device);

    var running = true;
    var last_ticks = c.SDL_GetTicksNS();
    var frame_count: u32 = 0;

    while (running) {
        input.beginFrame();
        running = pollInput(&input);
        const reload_events = try assets.reloadChanged();

        const now = c.SDL_GetTicksNS();
        const dt = ticksToSeconds(now - last_ticks);
        last_ticks = now;

        const steps = clock.push(dt);
        var step: u32 = 0;
        while (step < steps) : (step += 1) {
            try game.update(.{ .canvas = &canvas, .input = &input, .assets = &assets, .dt = clock.step_seconds });
        }

        canvas.clear(config.clear_color);
        try game.render(.{ .canvas = &canvas, .input = &input, .assets = &assets, .dt = dt });
        drawReloadOverlay(&canvas, reload_events);
        try presenter.present(device, window, canvas);

        frame_count += 1;
        if (config.max_frames) |max_frames| {
            if (frame_count >= max_frames) running = false;
        }
    }

    _ = c.SDL_WaitForGPUIdle(device);
}

fn playWithAllocator(allocator: std.mem.Allocator, config: Config, comptime Game: type) !void {
    if (config.width == 0 or config.height == 0 or config.scale == 0) return error.InvalidConfig;
    if (!c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_EVENTS)) return sdlFail("SDL_Init");
    defer c.SDL_Quit();

    const window_w = try scaledInt(config.width, config.scale);
    const window_h = try scaledInt(config.height, config.scale);
    const window = c.SDL_CreateWindow(config.title.ptr, window_w, window_h, 0) orelse return sdlFail("SDL_CreateWindow");
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

    var input = up.Input{};
    var clock = up.StepClock.init(config.fixed_hz);
    var presenter = try Presenter.init(device, config.width, config.height);
    defer presenter.deinit(device);

    var ctx = Context{ .canvas = &canvas, .input = &input, .assets = &assets, .dt = 0, .frame = 0 };
    var game = try initGame(Game, &ctx);
    defer deinitGame(Game, &game, &ctx);

    var running = true;
    var last_ticks = c.SDL_GetTicksNS();

    while (running) {
        input.beginFrame();
        running = pollInput(&input);
        const reload_events = try assets.reloadChanged();

        const now = c.SDL_GetTicksNS();
        const dt = ticksToSeconds(now - last_ticks);
        last_ticks = now;

        const steps = clock.push(dt);
        var step: u32 = 0;
        while (step < steps) : (step += 1) {
            ctx.dt = clock.step_seconds;
            try callUpdate(Game, &game, &ctx);
        }

        canvas.clear(config.clear_color);
        ctx.dt = dt;
        try callDraw(Game, &game, &ctx);
        drawReloadOverlay(&canvas, reload_events);
        try presenter.present(device, window, canvas);

        ctx.frame += 1;
        if (config.max_frames) |max_frames| {
            if (ctx.frame >= max_frames) running = false;
        }
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

const Presenter = struct {
    texture: *c.SDL_GPUTexture,
    transfer: *c.SDL_GPUTransferBuffer,
    width: u32,
    height: u32,
    byte_len: u32,

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

        return .{ .texture = texture, .transfer = transfer, .width = width, .height = height, .byte_len = byte_len };
    }

    fn deinit(self: *Presenter, device: *c.SDL_GPUDevice) void {
        c.SDL_ReleaseGPUTransferBuffer(device, self.transfer);
        c.SDL_ReleaseGPUTexture(device, self.texture);
        self.* = undefined;
    }

    fn present(self: *Presenter, device: *c.SDL_GPUDevice, window: *c.SDL_Window, canvas: up.Canvas) !void {
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
        if (swapchain) |target| {
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
                    .x = 0,
                    .y = 0,
                    .w = swap_w,
                    .h = swap_h,
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

fn pollInput(input: *up.Input) bool {
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
            else => {},
        }
    }
    return running;
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
