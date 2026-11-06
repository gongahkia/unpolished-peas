//! Independent scalar differential tests shared by native and freestanding Wasm.
const std = @import("std");
const builtin = @import("builtin");
const up = @import("unpolished-peas");
const reference = @import("surface_composition_reference.zig");
const workloads = @import("surface_composition_workloads.zig");
const Counter = @import("render_benchmark.zig").CountingAllocator;
const Case = struct {
    sw: u32,
    sh: u32,
    width: u32,
    height: u32,
    options: up.graphics.SurfaceDrawOptions,
    blend: up.graphics.BlendMode = .alpha,
    clip: ?up.graphics.ClipRect = null,
    pattern: ?workloads.Pattern = null,
};
const Report = struct { cases: u32 = 0, hash: u64 = 0 };
var result: Report = .{};
var failed_case: u32 = 0;
var failed_pixel: u32 = 0;

fn compareCase(allocator: std.mem.Allocator, case: Case, index: u32, hash: *std.hash.Fnv1a_64) !void {
    failed_case = index;
    var counter = Counter.init(allocator);
    var source = try up.graphics.RenderSurface.init(counter.allocator(), case.sw, case.sh);
    defer source.deinit();
    var actual = try up.graphics.Canvas.init(counter.allocator(), case.width, case.height);
    defer actual.deinit();
    var expected = try up.graphics.Canvas.init(allocator, case.width, case.height);
    defer expected.deinit();
    if (case.pattern) |pattern| workloads.populate(&source, pattern) else {
        var rng: u32 = index +% 0xa53c9e71;
        for (source.canvas().pixels) |*pixel| pixel.* = .{ .r = @truncate(next(&rng)), .g = @truncate(next(&rng) >> 8), .b = @truncate(next(&rng) >> 16), .a = @truncate(next(&rng) >> 24) };
    }
    var actual_trace = up.testSupport.CanvasTrace.init(allocator);
    defer actual_trace.deinit();
    var expected_trace = up.testSupport.CanvasTrace.init(allocator);
    defer expected_trace.deinit();
    for (0..2) |pass| {
        actual.clip = null;
        expected.clip = null;
        actual.blend = .alpha;
        expected.blend = .alpha;
        if (pass == 1) {
            actual.attachTrace(&actual_trace);
            expected.attachTrace(&expected_trace);
        }
        actual.clear(up.core.Color.rgba(13, 27, 51, 73));
        expected.clear(up.core.Color.rgba(13, 27, 51, 73));
        _ = actual.setBlend(case.blend);
        _ = expected.setBlend(case.blend);
        if (case.clip) |clip| {
            _ = actual.pushClip(clip);
            _ = expected.pushClip(clip);
        }
        if (pass == 1 and index % 3 == 0 and case.width >= 4 and case.height >= 4) {
            const nested = up.graphics.ClipRect{ .x = 1, .y = 2, .w = @as(i32, @intCast(case.width)) - 2, .h = @as(i32, @intCast(case.height)) - 3 };
            _ = actual.pushClip(nested);
            _ = expected.pushClip(nested);
        }
        actual.fillRect(1, 1, 3, 2, up.core.Color.rgba(171, 69, 21, 91));
        expected.fillRect(1, 1, 3, 2, up.core.Color.rgba(171, 69, 21, 91));
        counter.reset();
        try actual.drawSurface(&source, case.options);
        // Optional trace capture owns its own allocations. The normal draw
        // must make no successful allocation or buffer growth through its owner.
        if (pass == 0 and (counter.allocation_events != 0 or counter.allocated_bytes != 0)) return error.DrawAllocated;
        try reference.draw(&expected, &source, case.options);
        actual.fillRect(0, 0, 2, 2, up.core.Color.rgba(241, 87, 33, 167));
        expected.fillRect(0, 0, 2, 2, up.core.Color.rgba(241, 87, 33, 167));
        for (actual.pixels, expected.pixels, 0..) |a, b, pixel| if (!std.meta.eql(a, b)) {
            failed_pixel = @intCast(pixel);
            return error.SurfacePixelMismatch;
        };
        fold(hash, up.testSupport.canvasHash(actual));
    }
    if (try actual_trace.hash() != try expected_trace.hash()) return error.SurfaceTraceMismatch;
    fold(hash, try actual_trace.hash());
}

fn next(state: *u32) u32 {
    state.* = state.* *% 1664525 +% 1013904223;
    return state.*;
}
fn fold(hash: *std.hash.Fnv1a_64, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

fn suite(allocator: std.mem.Allocator) !Report {
    // A single bilinear expression would round 0.25 to 0 here. The contract
    // rounds the horizontal half to 1 first, then the vertical half to 1.
    try stagedRoundingBoundary(allocator);
    var hash = std.hash.Fnv1a_64.init();
    var count: u32 = 0;
    for (workloads.cases) |case| {
        try compareCase(allocator, .{ .sw = case.source_width, .sh = case.source_height, .width = case.width, .height = case.height, .options = case.options(), .blend = case.blend, .clip = case.clip, .pattern = case.pattern }, count, &hash);
        count += 1;
    }
    // Cross the proposed 128/256-pixel chunk boundaries, plus tiny/thin sources.
    for ([_]u32{ 1, 2, 3, 127, 128, 129, 255, 256, 257, 511, 512, 513, 1025 }) |width| {
        for ([_]up.graphics.BlendMode{ .alpha, .additive }) |blend| {
            try compareCase(allocator, .{ .sw = if (width % 2 == 0) 1 else 7, .sh = if (width % 3 == 0) 1 else 3, .width = width + 19, .height = 23, .options = .{ .x = 7, .y = -3, .width = width, .height = 19, .filter = .linear, .tint = up.core.Color.rgba(255, 173, 99, 137) }, .blend = blend }, count, &hash);
            count += 1;
        }
    }
    var rng: u32 = 0xcafebabe;
    for (0..512) |i| {
        const sw = 1 + next(&rng) % 63;
        const sh = 1 + next(&rng) % 37;
        const width = 1 + next(&rng) % 301;
        const height = 1 + next(&rng) % 53;
        const x = @as(i32, @intCast(next(&rng) % 81)) - 40;
        const y = @as(i32, @intCast(next(&rng) % 41)) - 20;
        const draw_width = 1 + next(&rng) % 600;
        const draw_height = 1 + next(&rng) % 100;
        const tint = up.core.Color.rgba(@truncate(next(&rng) >> 24), @truncate(next(&rng) >> 16), @truncate(next(&rng) >> 8), @truncate(next(&rng)));
        const clip: ?up.graphics.ClipRect = if (i % 3 == 0) .{ .x = -7, .y = 3, .w = @intCast(width), .h = @intCast(height / 2) } else null;
        try compareCase(allocator, .{ .sw = sw, .sh = sh, .width = width, .height = height, .options = .{ .x = x, .y = y, .width = draw_width, .height = draw_height, .filter = if (i % 5 == 0) .nearest else .linear, .tint = if (i % 7 == 0) up.core.Color.white else tint }, .blend = if (i % 2 == 0) .alpha else .additive, .clip = clip }, count, &hash);
        count += 1;
    }
    // Huge destination rectangles must remain safe and correctly clipped even
    // on wasm32: reference nearest-coordinate products deliberately use u64.
    for ([_]up.graphics.SurfaceFilter{ .nearest, .linear }) |filter| {
        try compareCase(allocator, .{ .sw = 3, .sh = 2, .width = 19, .height = 11, .options = .{ .x = -1000000000, .y = -1000000000, .width = std.math.maxInt(i32), .height = std.math.maxInt(i32), .filter = filter } }, count, &hash);
        count += 1;
        try compareCase(allocator, .{ .sw = 1, .sh = 1, .width = 1, .height = 1, .options = .{ .x = 0, .y = 0, .width = 1, .height = 1, .filter = filter } }, count, &hash);
        count += 1;
    }
    return .{ .cases = count, .hash = hash.final() };
}

fn stagedRoundingBoundary(allocator: std.mem.Allocator) !void {
    var source = try up.graphics.RenderSurface.init(allocator, 2, 2);
    defer source.deinit();
    source.canvas().clear(up.core.Color.black);
    source.canvas().pixels[1] = up.core.Color.rgb(1, 0, 0);
    var destination = try up.graphics.Canvas.init(allocator, 3, 3);
    defer destination.deinit();
    try destination.drawSurface(&source, .{ .x = 0, .y = 0, .width = 3, .height = 3, .filter = .linear });
    if (!std.meta.eql(destination.pixels[4], up.core.Color.rgb(1, 0, 0))) return error.StagedRoundingMismatch;
}

test "surface composition agrees exactly with independent scalar pixels and traces" {
    result = suite(std.testing.allocator) catch |err| {
        std.debug.print("surface case={d} pixel={d} error={s}\n", .{ failed_case, failed_pixel, @errorName(err) });
        return err;
    };
    try std.testing.expectEqual(@as(u32, 554), result.cases);
    try std.testing.expectEqual(@as(u64, 716431564172485137), result.hash);
}

pub export fn surface_conformance_run() u32 {
    result = suite(std.heap.page_allocator) catch return 1;
    return 0;
}
pub export fn surface_conformance_cases() u32 {
    return result.cases;
}
pub export fn surface_conformance_hash() u64 {
    return result.hash;
}
pub export fn surface_failure_case() u32 {
    return failed_case;
}
pub export fn surface_failure_pixel() u32 {
    return failed_pixel;
}
pub fn main() !void {
    if (comptime builtin.os.tag == .freestanding) return;
    result = try suite(std.heap.page_allocator);
    var bytes: [128]u8 = undefined;
    const output = try std.fmt.bufPrint(&bytes, "{{\"cases\":{d},\"hash\":\"{d}\"}}\n", .{ result.cases, result.hash });
    try std.fs.File.stdout().writeAll(output);
}
