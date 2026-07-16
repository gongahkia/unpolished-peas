const std = @import("std");
const builtin = @import("builtin");
const up = @import("unpolished-peas");
const bounce = @import("bounce.zig");
const platformer = @import("platformer_game.zig");
const topdown = @import("topdown_game.zig");
const content = @import("programmatic_content.zig");

const startup_samples: u32 = 16;
const frame_samples: u32 = 240;

const GameMetrics = struct {
    startup_ns: u64,
    startup_allocation_events: u64,
    startup_allocated_bytes: u64,
    frame_ns: u64,
    frame_allocation_events: u64,
    frame_allocated_bytes: u64,
};

const Metrics = struct {
    bounce: GameMetrics,
    topdown: GameMetrics,
    platformer: GameMetrics,
};

const CountingAllocator = struct {
    parent: std.mem.Allocator,
    allocation_events: u64 = 0,
    allocated_bytes: u64 = 0,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn init(parent: std.mem.Allocator) CountingAllocator {
        return .{ .parent = parent };
    }

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn reset(self: *CountingAllocator) void {
        self.allocation_events = 0;
        self.allocated_bytes = 0;
    }

    fn record(self: *CountingAllocator, bytes: usize) void {
        self.allocation_events +|= 1;
        self.allocated_bytes +|= bytes;
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        const result = self.parent.rawAlloc(len, alignment, ret_addr);
        if (result != null) self.record(len);
        return result;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        const resized = self.parent.rawResize(memory, alignment, new_len, ret_addr);
        if (resized and new_len > memory.len) self.record(new_len - memory.len);
        return resized;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        const result = self.parent.rawRemap(memory, alignment, new_len, ret_addr);
        if (result != null and new_len > memory.len) self.record(new_len - memory.len);
        return result;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.parent.rawFree(memory, alignment, ret_addr);
    }
};

const BounceRuntime = struct {
    canvas: up.Canvas = undefined,
    clock: up.StepClock = undefined,
    ball: bounce.Ball = .{},

    fn init(self: *BounceRuntime, allocator: std.mem.Allocator) !void {
        self.* = .{ .canvas = try up.Canvas.init(allocator, bounce.width, bounce.height), .clock = up.StepClock.init(60) };
    }

    fn deinit(self: *BounceRuntime) void {
        self.canvas.deinit();
        self.* = undefined;
    }

    fn frame(self: *BounceRuntime) !void {
        const steps = self.clock.push(1.0 / 60.0);
        var step: u32 = 0;
        while (step < steps) : (step += 1) self.ball.update(self.clock.step_seconds, @floatFromInt(self.canvas.width), @floatFromInt(self.canvas.height));
        self.canvas.clear(up.Color.rgb(14, 18, 24));
        var x: i32 = 0;
        while (x < @as(i32, @intCast(self.canvas.width))) : (x += 16) self.canvas.line(x, 0, x, @intCast(self.canvas.height - 1), up.Color.rgb(32, 39, 50));
        var y: i32 = 0;
        while (y < @as(i32, @intCast(self.canvas.height))) : (y += 16) self.canvas.line(0, y, @intCast(self.canvas.width - 1), y, up.Color.rgb(32, 39, 50));
        self.canvas.strokeRect(0, 0, @intCast(self.canvas.width), @intCast(self.canvas.height), up.Color.rgb(91, 104, 124));
        self.canvas.fillCircle(@intFromFloat(self.ball.pos.x), @intFromFloat(self.ball.pos.y), self.ball.radius, up.Color.rgb(255, 198, 74));
        self.canvas.drawText("UNPOLISHED", 4, 4, up.Color.rgb(225, 232, 240));
    }
};

const TopdownRuntime = struct {
    assets: up.AssetStore = undefined,
    map: up.TileMap = undefined,
    player: up.ImageHandle = undefined,
    game: topdown.Game = .{},
    input: up.Input = .{},
    canvas: up.Canvas = undefined,

    fn init(self: *TopdownRuntime, allocator: std.mem.Allocator) !void {
        self.assets = try up.AssetStore.initExecutable(allocator);
        errdefer self.assets.deinit();
        self.map = try content.topdownMap(allocator);
        errdefer self.map.deinit();
        self.player = try self.assets.loadImage("ball.png");
        self.input.set(.right, true);
        self.input.set(.down, true);
        self.canvas = try up.Canvas.init(allocator, topdown.width, topdown.height);
    }

    fn deinit(self: *TopdownRuntime) void {
        self.canvas.deinit();
        self.map.deinit();
        self.assets.deinit();
        self.* = undefined;
    }

    fn frame(self: *TopdownRuntime) !void {
        _ = self.game.step(self.input, 1.0 / 60.0);
        self.canvas.clear(up.Color.rgb(10, 18, 26));
        const camera = up.Camera2D{ .position = self.game.player };
        const images = [_]up.Image{try self.assets.tryImage(self.player)};
        self.map.drawImages(up.CameraCanvas.init(&self.canvas, &camera), &images);
        self.canvas.drawImage(try self.assets.tryImage(self.player), @intFromFloat(self.game.player.x - 8), @intFromFloat(self.game.player.y - 8));
        self.canvas.drawText("TOPDOWN", 4, 4, up.Color.white);
        self.canvas.drawText("ARROWS SPACE", 84, 4, up.Color.rgb(180, 205, 230));
    }
};

const PlatformerRuntime = struct {
    assets: up.AssetStore = undefined,
    map: up.TileMap = undefined,
    collider: up.TileCollider = undefined,
    atlas: *up.Atlas = undefined,
    tile_image: up.ImageHandle = undefined,
    animation: up.AnimationPlayer = undefined,
    game: platformer.Game = undefined,
    frame_index: u32 = 0,
    canvas: up.Canvas = undefined,

    fn init(self: *PlatformerRuntime, allocator: std.mem.Allocator) !void {
        self.assets = try up.AssetStore.initExecutable(allocator);
        errdefer self.assets.deinit();
        const generated_map = try content.platformerMap(allocator);
        self.map = generated_map.map;
        errdefer self.map.deinit();
        self.collider = up.TileCollider.init(allocator);
        errdefer self.collider.deinit();
        try self.collider.addLayer(&self.map, generated_map.collision_layer);
        self.tile_image = try self.assets.loadImage("ball.png");
        self.atlas = try allocator.create(up.Atlas);
        errdefer allocator.destroy(self.atlas);
        self.atlas.* = try content.ballAtlas(allocator, try self.assets.tryImage(self.tile_image));
        errdefer self.atlas.deinit();
        const animation_handle = self.atlas.findAnimation("pulse") orelse return error.MissingAtlasAnimation;
        self.animation = up.AnimationPlayer.init(self.atlas, animation_handle);
        self.game = try platformer.Game.init(.{ .x = 8, .y = 0 });
        self.canvas = try up.Canvas.init(allocator, 160, 64);
    }

    fn deinit(self: *PlatformerRuntime) void {
        self.canvas.deinit();
        self.collider.deinit();
        self.map.deinit();
        const allocator = self.atlas.allocator;
        self.atlas.deinit();
        allocator.destroy(self.atlas);
        self.assets.deinit();
        self.* = undefined;
    }

    fn frame(self: *PlatformerRuntime) !void {
        _ = self.game.step(&self.collider, .{ .right = self.frame_index < 48, .jump = self.frame_index == 48 }, 1.0 / 60.0);
        self.animation.update(1.0 / 60.0);
        self.frame_index +%= 1;
        self.canvas.clear(up.Color.rgb(12, 18, 28));
        const camera = up.Camera2D{ .position = .{ .x = 48, .y = 24 } };
        const images = [_]up.Image{try self.assets.tryImage(self.tile_image)};
        self.map.drawImages(up.CameraCanvas.init(&self.canvas, &camera), &images);
        self.canvas.drawAtlasFrame(self.atlas.*, self.animation.frame(), @intFromFloat(self.game.controller.bounds.x), @intFromFloat(self.game.controller.bounds.y), .{ .scale = 2 });
        self.canvas.fillCircle(84, 8, 2, up.Color.rgb(255, 198, 74));
        self.canvas.drawText("PLATFORMER", 2, 2, up.Color.white);
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const metrics = try measureAll(gpa.allocator());

    var buffer: [2048]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buffer);
    const out = &writer.interface;
    try out.print(
        \\{{
        \\  "version": 1,
        \\  "target": "{s}-{s}",
        \\  "game_metrics": {{
        \\    "bounce": {{"startup_ns": {d}, "startup_allocation_events": {d}, "startup_allocated_bytes": {d}, "frame_ns": {d}, "frame_allocation_events": {d}, "frame_allocated_bytes": {d}}},
        \\    "topdown": {{"startup_ns": {d}, "startup_allocation_events": {d}, "startup_allocated_bytes": {d}, "frame_ns": {d}, "frame_allocation_events": {d}, "frame_allocated_bytes": {d}}},
        \\    "platformer": {{"startup_ns": {d}, "startup_allocation_events": {d}, "startup_allocated_bytes": {d}, "frame_ns": {d}, "frame_allocation_events": {d}, "frame_allocated_bytes": {d}}}
        \\  }}
        \\}}
    ,
        .{
            @tagName(builtin.os.tag),
            @tagName(builtin.cpu.arch),
            metrics.bounce.startup_ns,
            metrics.bounce.startup_allocation_events,
            metrics.bounce.startup_allocated_bytes,
            metrics.bounce.frame_ns,
            metrics.bounce.frame_allocation_events,
            metrics.bounce.frame_allocated_bytes,
            metrics.topdown.startup_ns,
            metrics.topdown.startup_allocation_events,
            metrics.topdown.startup_allocated_bytes,
            metrics.topdown.frame_ns,
            metrics.topdown.frame_allocation_events,
            metrics.topdown.frame_allocated_bytes,
            metrics.platformer.startup_ns,
            metrics.platformer.startup_allocation_events,
            metrics.platformer.startup_allocated_bytes,
            metrics.platformer.frame_ns,
            metrics.platformer.frame_allocation_events,
            metrics.platformer.frame_allocated_bytes,
        },
    );
    try out.flush();
}

fn measureAll(allocator: std.mem.Allocator) !Metrics {
    return .{
        .bounce = try measure(BounceRuntime, allocator),
        .topdown = try measure(TopdownRuntime, allocator),
        .platformer = try measure(PlatformerRuntime, allocator),
    };
}

fn measure(comptime Runtime: type, allocator: std.mem.Allocator) !GameMetrics {
    var counter = CountingAllocator.init(allocator);
    const measured_allocator = counter.allocator();
    var timer = try std.time.Timer.start();
    var startup_ns: u64 = 0;
    var startup_allocation_events: u64 = 0;
    var startup_allocated_bytes: u64 = 0;
    var sample: u32 = 0;
    while (sample < startup_samples) : (sample += 1) {
        counter.reset();
        timer.reset();
        {
            var runtime: Runtime = undefined;
            try runtime.init(measured_allocator);
            defer runtime.deinit();
            try runtime.frame();
            std.mem.doNotOptimizeAway(runtime.canvas.pixels);
        }
        startup_ns +|= timer.read();
        startup_allocation_events +|= counter.allocation_events;
        startup_allocated_bytes +|= counter.allocated_bytes;
    }

    var runtime: Runtime = undefined;
    try runtime.init(measured_allocator);
    defer runtime.deinit();
    try runtime.frame();
    counter.reset();
    timer.reset();
    sample = 0;
    while (sample < frame_samples) : (sample += 1) try runtime.frame();
    const frame_ns = timer.read() / frame_samples;
    std.mem.doNotOptimizeAway(runtime.canvas.pixels);
    return .{
        .startup_ns = startup_ns / startup_samples,
        .startup_allocation_events = startup_allocation_events / startup_samples,
        .startup_allocated_bytes = startup_allocated_bytes / startup_samples,
        .frame_ns = frame_ns,
        .frame_allocation_events = counter.allocation_events,
        .frame_allocated_bytes = counter.allocated_bytes,
    };
}
