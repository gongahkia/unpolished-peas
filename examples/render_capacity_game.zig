//! Internal mixed GameProtocol workload; no benchmark hooks enter the game API.
const std = @import("std");
const builtin = @import("builtin");
const up = @import("unpolished-peas");
const Counter = @import("render-counter").CountingAllocator;
pub const sprite_count = 1000;
pub const label_count = 12;
pub const max_samples = 1024;
pub var linear = false;
pub var gpu = false;
var active: ?*Game = null;
var clock: ?std.time.Timer = null;
extern "env" fn peas_benchmark_now_ms() f64;
pub fn nowMs() f64 {
    if (comptime builtin.cpu.arch == .wasm32) return peas_benchmark_now_ms();
    return @as(f64, @floatFromInt(clock.?.read())) / std.time.ns_per_ms;
}
// All f64 fields make this private observation buffer portable to JavaScript.
pub const Sample = extern struct {
    update_ms: f64,
    draw_ms: f64,
    sprites_ms: f64,
    text_ms: f64,
    composition_ms: f64,
    allocation_events: f64,
    allocated_bytes: f64,
    updates: f64,
};

pub const Game = struct {
    counter: Counter = undefined,
    assets: ?up.assets.AssetCollection = null,
    layout: ?up.assets.Font.TextLayout = null,
    world: ?up.graphics.RenderSurface = null,
    overlay: ?up.graphics.RenderSurface = null,
    compositor: ?up.graphics.SurfaceCompositor = null,
    world_layer: up.graphics.SurfaceCompositor.Layer = undefined,
    overlay_layer: up.graphics.SurfaceCompositor.Layer = undefined,
    headless_target: ?up.graphics.Canvas = null,
    solid_pixels: [16 * 16]up.core.Color = undefined,
    alpha: [16 * 16]up.core.Color = undefined,
    tick: u32 = 0,
    positions: [sprite_count]struct { x: i32, y: i32 } = undefined,
    frozen: bool = false,
    update_ms: f64 = 0,
    updates: f64 = 0,
    samples: [max_samples]Sample = undefined,
    count: usize = 0,
    dropped: usize = 0,

    pub fn init(self: *Game, ctx: *up.core.GameContext) !void {
        if (comptime builtin.cpu.arch != .wasm32) clock = try std.time.Timer.start();
        self.counter = Counter.init(try ctx.requireAllocator());
        const allocator = self.counter.allocator();
        errdefer self.deinit(ctx) catch {};
        self.assets = up.assets.AssetCollection.init(allocator);
        const font = try self.assets.?.font(@embedFile("assets/fonts/SourceSans3-Regular.otf"), .{ .pixel_height = 14 });
        self.layout = try font.layoutText(allocator, "Willow iii WWW — Zoë\nFind the lantern by the bridge.", .{ .max_width = 210, .alignment = .center });
        self.world = try up.graphics.RenderSurface.init(allocator, 320, 180);
        self.overlay = try up.graphics.RenderSurface.init(allocator, 160, 90);
        if (gpu) {
            self.compositor = try up.graphics.SurfaceCompositor.init(allocator, .{ .layers = 2, .draws = 4 });
            self.world_layer = try self.compositor.?.retain(&self.world.?);
            self.overlay_layer = try self.compositor.?.retain(&self.overlay.?);
            if (ctx.renderer == null) {
                const canvas = try ctx.requireCanvas();
                self.headless_target = try up.graphics.Canvas.init(allocator, canvas.width, canvas.height);
            }
        }
        for (&self.solid_pixels, &self.alpha, 0..) |*solid, *alpha, i| {
            solid.* = up.core.Color.rgb(@intCast(40 + i % 180), @intCast(70 + i % 120), 140);
            alpha.* = up.core.Color.rgba(210, @intCast(60 + i % 150), 70, if (i % 7 == 0) 0 else 128);
        }
        active = self;
        self.placeSprites();
        self.counter.reset();
    }
    pub fn placeSprites(self: *Game) void {
        for (&self.positions, 0..) |*position, i| position.* = .{
            .x = @as(i32, @intCast((i * 37 + self.tick % 320) % 336)) - 8,
            .y = @as(i32, @intCast((i * 23 + self.tick % 180) % 196)) - 8,
        };
    }
    pub fn update(self: *Game, _: *up.core.GameContext, _: f32) !void {
        const started = nowMs();
        // Fixed integer simulation, independent of the callback clock.
        if (!self.frozen) self.tick +%= 1;
        self.placeSprites();
        std.mem.doNotOptimizeAway(&self.positions);
        self.update_ms += nowMs() - started;
        self.updates += 1;
    }
    pub fn draw(self: *Game, ctx: *up.core.GameContext) !void {
        const started = nowMs();
        const canvas = try ctx.requireCanvas();
        const previous_alpha = canvas.preserve_alpha;
        defer canvas.preserve_alpha = previous_alpha;
        canvas.preserve_alpha = gpu;
        canvas.clear(if (gpu) up.core.Color.transparent else up.core.Color.rgb(13, 21, 30));
        const world = self.world.?.canvas();
        const overlay = self.overlay.?.canvas();
        world.clear(up.core.Color.rgb(18, 34, 45));
        overlay.clear(up.core.Color.transparent);
        for (0..sprite_count) |i| {
            world.drawSprite(.{ .width = 16, .height = 16, .pixels = if (i % 4 == 0) &self.alpha else &self.solid_pixels }, self.positions[i].x, self.positions[i].y);
        }
        for (0..64) |i| overlay.fillRect(@intCast(i * 17 % 160), @intCast(i * 11 % 90), 18, 10, up.core.Color.rgba(80, 160, 220, 100));
        const sprites_done = nowMs();
        const filter: up.graphics.SurfaceFilter = if (linear) .linear else .nearest;
        if (self.compositor) |*scene| {
            try scene.beginFrame(up.core.Color.rgb(13, 21, 30));
            try scene.drawLayer(self.world_layer, .{ .surface = .{ .x = 0, .y = 0, .width = canvas.width, .height = canvas.height, .filter = filter } });
            try scene.drawLayer(self.overlay_layer, .{ .surface = .{ .x = 0, .y = 0, .width = canvas.width, .height = canvas.height, .filter = filter } });
            try scene.drawCanvas();
            if (ctx.renderer) |renderer| try renderer.composeSurfaces(scene);
        } else {
            try canvas.drawSurface(&self.world.?, .{ .x = 0, .y = 0, .width = canvas.width, .height = canvas.height, .filter = filter });
            try canvas.drawSurface(&self.overlay.?, .{ .x = 0, .y = 0, .width = canvas.width, .height = canvas.height, .filter = filter });
        }
        const composition_done = nowMs();
        for (0..label_count) |i| self.layout.?.draw(canvas, @intCast(i * 73 % (canvas.width - 210)), @intCast(i * 31 % (canvas.height - 32)), up.core.Color.white);
        if (self.headless_target) |*target| {
            try self.compositor.?.drawCpu(target, canvas);
            @memcpy(canvas.pixels, target.pixels);
        }
        const finished = nowMs();
        if (self.count < self.samples.len) {
            self.samples[self.count] = .{
                .update_ms = self.update_ms,
                .draw_ms = finished - started,
                .sprites_ms = sprites_done - started,
                .text_ms = finished - composition_done,
                .composition_ms = composition_done - sprites_done,
                .allocation_events = @floatFromInt(self.counter.allocation_events),
                .allocated_bytes = @floatFromInt(self.counter.allocated_bytes),
                .updates = self.updates,
            };
            self.count += 1;
        } else self.dropped += 1;
        self.update_ms = 0;
        self.updates = 0;
        self.counter.reset();
    }
    pub fn deinit(self: *Game, _: *up.core.GameContext) !void {
        if (self.compositor) |*value| value.deinit();
        if (self.headless_target) |*value| value.deinit();
        if (self.layout) |*value| value.deinit();
        if (self.assets) |*value| value.deinit();
        if (self.world) |*value| value.deinit();
        if (self.overlay) |*value| value.deinit();
        self.layout = null;
        self.assets = null;
        self.world = null;
        self.overlay = null;
        self.compositor = null;
        self.headless_target = null;
        active = null;
    }
};

pub export fn peas_capacity_samples() usize {
    return if (active) |game| @intFromPtr(&game.samples) else 0;
}
pub export fn peas_capacity_count() usize {
    return if (active) |game| game.count else 0;
}
pub export fn peas_capacity_dropped() usize {
    return if (active) |game| game.dropped else 0;
}
pub export fn peas_capacity_linear(value: u32) void {
    linear = value != 0;
}
pub export fn peas_capacity_gpu(value: u32) void {
    gpu = value != 0;
}
pub export fn peas_capacity_freeze(tick: u32) void {
    if (active) |game| {
        game.frozen = true;
        game.tick = tick;
        game.placeSprites();
    }
}
