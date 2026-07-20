const std = @import("std");
const builtin = @import("builtin");
const up = @import("unpolished-peas");
const bounce = @import("bounce.zig");
const puzzle = @import("puzzle_game.zig");

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
    puzzle: GameMetrics,
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
    canvas: up.graphics.Canvas = undefined,
    clock: up.core.StepClock = undefined,
    ball: bounce.Ball = .{},

    fn init(self: *BounceRuntime, allocator: std.mem.Allocator) !void {
        self.* = .{ .canvas = try up.graphics.Canvas.init(allocator, bounce.width, bounce.height), .clock = up.core.StepClock.init(60) };
    }

    fn deinit(self: *BounceRuntime) void {
        self.canvas.deinit();
        self.* = undefined;
    }

    fn frame(self: *BounceRuntime) !void {
        const steps = self.clock.push(1.0 / 60.0);
        var step: u32 = 0;
        while (step < steps) : (step += 1) self.ball.update(self.clock.step_seconds, @floatFromInt(self.canvas.width), @floatFromInt(self.canvas.height));
        self.canvas.clear(up.core.Color.rgb(14, 18, 24));
        var x: i32 = 0;
        while (x < @as(i32, @intCast(self.canvas.width))) : (x += 16) self.canvas.line(x, 0, x, @intCast(self.canvas.height - 1), up.core.Color.rgb(32, 39, 50));
        var y: i32 = 0;
        while (y < @as(i32, @intCast(self.canvas.height))) : (y += 16) self.canvas.line(0, y, @intCast(self.canvas.width - 1), y, up.core.Color.rgb(32, 39, 50));
        self.canvas.strokeRect(0, 0, @intCast(self.canvas.width), @intCast(self.canvas.height), up.core.Color.rgb(91, 104, 124));
        self.canvas.fillCircle(@intFromFloat(self.ball.pos.x), @intFromFloat(self.ball.pos.y), self.ball.radius, up.core.Color.rgb(255, 198, 74));
        self.canvas.drawText("UNPOLISHED", 4, 4, up.core.Color.rgb(225, 232, 240));
    }
};

const PuzzleRuntime = struct {
    canvas: up.graphics.Canvas = undefined,
    game: puzzle.Game = .{},
    input: up.input.Input = .{},
    frame_index: u32 = 0,

    fn init(self: *PuzzleRuntime, allocator: std.mem.Allocator) !void {
        self.* = .{ .canvas = try up.graphics.Canvas.init(allocator, puzzle.width, puzzle.height) };
    }

    fn deinit(self: *PuzzleRuntime) void {
        self.canvas.deinit();
        self.* = undefined;
    }

    fn frame(self: *PuzzleRuntime) !void {
        self.input.set(.action, self.frame_index % 60 == 0);
        _ = self.game.step(self.input);
        self.frame_index +%= 1;
        self.canvas.clear(up.core.Color.rgb(13, 18, 30));
        for (self.game.cells, 0..) |lit, index| {
            const x = 45 + @as(i32, @intCast(index % puzzle.columns)) * 24;
            const y = 24 + @as(i32, @intCast(index / puzzle.columns)) * 24;
            self.canvas.fillRect(x, y, 20, 20, if (lit) up.core.Color.rgb(113, 232, 162) else up.core.Color.rgb(31, 47, 68));
            self.canvas.strokeRect(x, y, 20, 20, if (index == self.game.selected) up.core.Color.rgb(255, 198, 74) else up.core.Color.rgb(91, 124, 158));
        }
        self.canvas.drawText("LIGHTS OUT", 4, 4, up.core.Color.white);
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
        \\    "puzzle": {{"startup_ns": {d}, "startup_allocation_events": {d}, "startup_allocated_bytes": {d}, "frame_ns": {d}, "frame_allocation_events": {d}, "frame_allocated_bytes": {d}}}
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
            metrics.puzzle.startup_ns,
            metrics.puzzle.startup_allocation_events,
            metrics.puzzle.startup_allocated_bytes,
            metrics.puzzle.frame_ns,
            metrics.puzzle.frame_allocation_events,
            metrics.puzzle.frame_allocated_bytes,
        },
    );
    try out.flush();
}

fn measureAll(allocator: std.mem.Allocator) !Metrics {
    return .{
        .bounce = try measure(BounceRuntime, allocator),
        .puzzle = try measure(PuzzleRuntime, allocator),
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
