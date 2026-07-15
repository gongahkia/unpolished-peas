const std = @import("std");
const builtin = @import("builtin");
const up = @import("unpolished-peas").api;

const startup_samples: u32 = 32;
const frame_samples: u32 = 240;

const Metrics = struct {
    startup_ns: u64,
    frame_ns: u64,
    frame_allocation_events: u64,
    frame_allocated_bytes: u64,
    profiler_frame_ns: u64,
    profiler_frame_allocation_events: u64,
    profiler_frame_allocated_bytes: u64,
    runtime_metrics_frame_ns: u64,
    runtime_metrics_frame_allocation_events: u64,
    runtime_metrics_frame_allocated_bytes: u64,
    renderer_ns: u64,
    renderer_allocation_events: u64,
    renderer_allocated_bytes: u64,
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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    const metrics = try measure(allocator);

    var buffer: [1024]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buffer);
    try writer.interface.print(
        \\{{
        \\  "version": 1,
        \\  "target": "{s}-{s}",
        \\  "metrics": {{
        \\    "startup_ns": {d},
        \\    "frame_ns": {d},
        \\    "frame_allocation_events": {d},
        \\    "frame_allocated_bytes": {d},
        \\    "profiler_frame_ns": {d},
        \\    "profiler_frame_allocation_events": {d},
        \\    "profiler_frame_allocated_bytes": {d},
        \\    "runtime_metrics_frame_ns": {d},
        \\    "runtime_metrics_frame_allocation_events": {d},
        \\    "runtime_metrics_frame_allocated_bytes": {d},
        \\    "renderer_ns": {d},
        \\    "renderer_allocation_events": {d},
        \\    "renderer_allocated_bytes": {d}
        \\  }}
        \\}}
    ,
        .{
            @tagName(builtin.os.tag),
            @tagName(builtin.cpu.arch),
            metrics.startup_ns,
            metrics.frame_ns,
            metrics.frame_allocation_events,
            metrics.frame_allocated_bytes,
            metrics.profiler_frame_ns,
            metrics.profiler_frame_allocation_events,
            metrics.profiler_frame_allocated_bytes,
            metrics.runtime_metrics_frame_ns,
            metrics.runtime_metrics_frame_allocation_events,
            metrics.runtime_metrics_frame_allocated_bytes,
            metrics.renderer_ns,
            metrics.renderer_allocation_events,
            metrics.renderer_allocated_bytes,
        },
    );
    try writer.interface.flush();
}

fn measure(allocator: std.mem.Allocator) !Metrics {
    var counter = CountingAllocator.init(allocator);
    const measured_allocator = counter.allocator();
    const startup_ns = try measureStartup(measured_allocator);

    var canvas = try up.Canvas.init(measured_allocator, 160, 90);
    defer canvas.deinit();
    var commands = up.RenderCommandBuffer.init(measured_allocator);
    defer commands.deinit();
    try appendRendererWorkload(&commands);
    var renderer = up.HeadlessRenderer.init(&canvas);
    defer renderer.deinit(measured_allocator);
    try renderer.submit(measured_allocator, commands.commands.items);

    counter.reset();
    const frame_ns = try measureFrame(&canvas);
    const frame_allocation_events = counter.allocation_events;
    const frame_allocated_bytes = counter.allocated_bytes;

    counter.reset();
    const profiler_frame_ns = measureProfilerFrame();
    const profiler_frame_allocation_events = counter.allocation_events;
    const profiler_frame_allocated_bytes = counter.allocated_bytes;

    counter.reset();
    const runtime_metrics_frame_ns = measureRuntimeMetricsFrame();
    const runtime_metrics_frame_allocation_events = counter.allocation_events;
    const runtime_metrics_frame_allocated_bytes = counter.allocated_bytes;

    counter.reset();
    const renderer_ns = try measureRenderer(&canvas, &renderer, measured_allocator, commands.commands.items);
    const renderer_allocation_events = counter.allocation_events;
    const renderer_allocated_bytes = counter.allocated_bytes;
    return .{
        .startup_ns = startup_ns,
        .frame_ns = frame_ns,
        .frame_allocation_events = frame_allocation_events,
        .frame_allocated_bytes = frame_allocated_bytes,
        .profiler_frame_ns = profiler_frame_ns,
        .profiler_frame_allocation_events = profiler_frame_allocation_events,
        .profiler_frame_allocated_bytes = profiler_frame_allocated_bytes,
        .runtime_metrics_frame_ns = runtime_metrics_frame_ns,
        .runtime_metrics_frame_allocation_events = runtime_metrics_frame_allocation_events,
        .runtime_metrics_frame_allocated_bytes = runtime_metrics_frame_allocated_bytes,
        .renderer_ns = renderer_ns,
        .renderer_allocation_events = renderer_allocation_events,
        .renderer_allocated_bytes = renderer_allocated_bytes,
    };
}

fn measureStartup(allocator: std.mem.Allocator) !u64 {
    var timer = try std.time.Timer.start();
    var total_ns: u64 = 0;
    var sample: u32 = 0;
    while (sample < startup_samples) : (sample += 1) {
        timer.reset();
        var canvas = try up.Canvas.init(allocator, 160, 90);
        var commands = up.RenderCommandBuffer.init(allocator);
        try appendRendererWorkload(&commands);
        var renderer = up.HeadlessRenderer.init(&canvas);
        try renderer.submit(allocator, commands.commands.items);
        std.mem.doNotOptimizeAway(canvas.pixels);
        renderer.deinit(allocator);
        commands.deinit();
        canvas.deinit();
        total_ns +|= timer.read();
    }
    return total_ns / startup_samples;
}

fn measureFrame(canvas: *up.Canvas) !u64 {
    var timer = try std.time.Timer.start();
    var sample: u32 = 0;
    while (sample < frame_samples) : (sample += 1) {
        drawFrame(canvas, sample);
    }
    const elapsed = timer.read();
    std.mem.doNotOptimizeAway(canvas.pixels);
    return elapsed / frame_samples;
}

fn measureProfilerFrame() u64 {
    var profiler = up.FrameProfiler.init(true);
    var timer = std.time.Timer.start() catch unreachable;
    var sample: u32 = 0;
    while (sample < frame_samples) : (sample += 1) {
        profiler.beginFrame(sample);
        inline for ([_]up.ProfileScope{ .callback, .asset, .update, .draw }) |scope| profiler.scope(scope).end();
    }
    std.mem.doNotOptimizeAway(profiler.metrics());
    return timer.read() / frame_samples;
}

fn measureRuntimeMetricsFrame() u64 {
    var metrics = up.RuntimeMetrics{};
    var timer = std.time.Timer.start() catch unreachable;
    var sample: u32 = 0;
    while (sample < frame_samples) : (sample += 1) {
        metrics.beginFrame(sample);
        metrics.recordAssetReloads(1);
        metrics.recordGpuSubmission(100, 3, 2, 4, 4096, 8192);
        metrics.recordAudio(1024, 256);
    }
    std.mem.doNotOptimizeAway(metrics);
    return timer.read() / frame_samples;
}

fn measureRenderer(canvas: *up.Canvas, renderer: *up.HeadlessRenderer, allocator: std.mem.Allocator, commands: []const up.RenderCommand) !u64 {
    var timer = try std.time.Timer.start();
    var sample: u32 = 0;
    while (sample < frame_samples) : (sample += 1) try renderer.submit(allocator, commands);
    const elapsed = timer.read();
    std.mem.doNotOptimizeAway(canvas.pixels);
    return elapsed / frame_samples;
}

fn drawFrame(canvas: *up.Canvas, sample: u32) void {
    canvas.clear(up.Color.rgb(14, 18, 24));
    const offset: i32 = @intCast(sample % 48);
    canvas.fillRect(8 + offset, 8, 48, 24, up.Color.rgb(91, 166, 210));
    canvas.strokeRect(4, 4, 152, 82, up.Color.rgb(225, 232, 240));
    canvas.fillCircle(80, 45, 18, up.Color.rgb(255, 198, 74));
    canvas.fillTriangle(.{ .x = 16, .y = 72 }, .{ .x = 52, .y = 32 }, .{ .x = 88, .y = 72 }, up.Color.rgb(113, 232, 162));
    canvas.drawText("PERF", 4, 4, up.Color.white);
}

fn appendRendererWorkload(commands: *up.RenderCommandBuffer) !void {
    try commands.append(.{ .begin_frame = up.Color.rgb(14, 18, 24) });
    try commands.append(.{ .push_clip = .{ .x = 4, .y = 4, .w = 152, .h = 82 } });
    try commands.append(.{ .rect = .{ .x = 8, .y = 8, .w = 48, .h = 24, .color = up.Color.rgb(91, 166, 210) } });
    try commands.append(.{ .circle = .{ .x = 80, .y = 45, .radius = 18, .color = up.Color.rgb(255, 198, 74) } });
    try commands.append(.{ .triangle = .{ .a = .{ .x = 16, .y = 72 }, .b = .{ .x = 52, .y = 32 }, .c = .{ .x = 88, .y = 72 }, .color = up.Color.rgb(113, 232, 162) } });
    try commands.append(.pop_clip);
    try commands.append(.{ .stroke_rect = .{ .x = 4, .y = 4, .w = 152, .h = 82, .color = up.Color.rgb(225, 232, 240) } });
}
