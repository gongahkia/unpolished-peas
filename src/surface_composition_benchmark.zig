//! CPU composition only: no renderer upload, window, presentation or GPU work.
const std = @import("std");
const builtin = @import("builtin");
const up = @import("unpolished-peas");
const workloads = @import("surface_composition_workloads.zig");
const Counter = @import("render_benchmark.zig").CountingAllocator;
const warmup = 4;
const target_pixels = 48 * 1024 * 1024;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    var rounds: u32 = 1;
    var selected: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return error.InvalidArguments;
        if (std.mem.eql(u8, args[i], "--rounds")) rounds = try std.fmt.parseInt(u32, args[i + 1], 10) else if (std.mem.eql(u8, args[i], "--case")) selected = args[i + 1] else return error.InvalidArguments;
    }
    if (rounds == 0 or rounds > 100) return error.InvalidArguments;
    var buffer: [8192]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buffer);
    const out = &writer.interface;
    for (0..rounds) |sample| {
        var found = false;
        for (workloads.cases) |case| {
            if (selected) |name| if (!std.mem.eql(u8, name, case.name)) continue;
            found = true;
            var counter = Counter.init(allocator);
            var source = try up.graphics.RenderSurface.init(counter.allocator(), case.source_width, case.source_height);
            defer source.deinit();
            var destination = try up.graphics.Canvas.init(counter.allocator(), case.width, case.height);
            defer destination.deinit();
            workloads.populate(&source, case.pattern);
            destination.clear(up.core.Color.rgba(13, 27, 51, 73));
            _ = destination.setBlend(case.blend);
            if (case.clip) |clip| _ = destination.pushClip(clip);
            const iterations: u32 = @intCast(std.math.clamp(std.math.divCeil(u64, target_pixels, @max(1, case.visiblePixels())) catch unreachable, 8, 8192));
            for (0..warmup) |_| try destination.drawSurface(&source, case.options());
            counter.reset();
            var timer = try std.time.Timer.start();
            for (0..iterations) |_| {
                try destination.drawSurface(&source, case.options());
                std.mem.doNotOptimizeAway(destination.pixels.ptr);
            }
            const elapsed = timer.read();
            var hash_buffer: [16]u8 = undefined;
            const hash = try std.fmt.bufPrint(&hash_buffer, "{x:0>16}", .{up.testSupport.canvasHash(destination)});
            const json = try std.json.Stringify.valueAlloc(allocator, .{
                .schema = "surface-composition-v1",
                .target = @tagName(builtin.os.tag) ++ "-" ++ @tagName(builtin.cpu.arch),
                .mode = @tagName(builtin.mode),
                .sample = sample,
                .name = case.name,
                .source_width = case.source_width,
                .source_height = case.source_height,
                .width = case.width,
                .height = case.height,
                .visible_pixels = case.visiblePixels(),
                .pattern = case.pattern,
                .filter = case.filter,
                .tint = case.tint,
                .blend = case.blend,
                .x = case.x,
                .y = case.y,
                .clip = case.clip,
                .warmup_iterations = warmup,
                .target_pixels = target_pixels,
                .iterations = iterations,
                .elapsed_ns = elapsed,
                .average_ns = elapsed / iterations,
                .allocations = counter.allocation_events,
                .allocated_bytes = counter.allocated_bytes,
                .pixel_hash = hash,
            }, .{});
            defer allocator.free(json);
            try out.print("{s}\n", .{json});
            try out.flush();
        }
        if (!found) return error.UnknownWorkload;
    }
}
