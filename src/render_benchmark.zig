// Internal ReleaseFast rendering microbenchmarks. This executable is not part
// of the public Peas API or its compatibility contract.
const std = @import("std");
const builtin = @import("builtin");
const up = @import("unpolished-peas");

const warmup_iterations: u32 = 4;
const target_pixels: u64 = 48 * 1024 * 1024;

const Size = struct { width: u32, height: u32 };
const sizes = [_]Size{
    .{ .width = 160, .height = 90 },
    .{ .width = 320, .height = 180 },
    .{ .width = 640, .height = 360 },
    .{ .width = 1280, .height = 720 },
    .{ .width = 1920, .height = 1080 },
};

const Measurement = struct {
    name: []const u8,
    width: u32,
    height: u32,
    iterations: u32,
    elapsed_ns: u64,
    commands_per_iteration: u64,
    pixels_per_iteration: u64,
    allocation_events: u64,
    allocated_bytes: u64,
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

    var output: [96]Measurement = undefined;
    var count: usize = 0;
    for (sizes) |size| {
        output[count] = try measureClear(allocator, size);
        count += 1;
        output[count] = try measureCanvasCopy(allocator, size);
        count += 1;
    }
    for ([_]Size{ sizes[1], sizes[3] }) |size| {
        output[count] = try measureRects(allocator, size, 100, false);
        count += 1;
        output[count] = try measureRects(allocator, size, 1_000, false);
        count += 1;
        output[count] = try measureRects(allocator, size, 100, true);
        count += 1;
        output[count] = try measureLines(allocator, size, 100);
        count += 1;
        output[count] = try measureCircles(allocator, size, 100);
        count += 1;
        output[count] = try measureSprites(allocator, size, 100, SpriteAlpha.fully_opaque, SpritePlacement.visible);
        count += 1;
        output[count] = try measureSprites(allocator, size, 1_000, SpriteAlpha.fully_opaque, SpritePlacement.visible);
        count += 1;
        output[count] = try measureSprites(allocator, size, 5_000, SpriteAlpha.fully_opaque, SpritePlacement.visible);
        count += 1;
        output[count] = try measureSprites(allocator, size, 1_000, SpriteAlpha.translucent, SpritePlacement.visible);
        count += 1;
        output[count] = try measureSprites(allocator, size, 1_000, SpriteAlpha.translucent, SpritePlacement.partially_clipped);
        count += 1;
        output[count] = try measureSprites(allocator, size, 1_000, SpriteAlpha.fully_opaque, SpritePlacement.offscreen);
        count += 1;
        output[count] = try measureAtlas(allocator, size, 1_000);
        count += 1;
        output[count] = try measureBuiltinText(allocator, size, 5);
        count += 1;
        output[count] = try measureBuiltinText(allocator, size, 100);
        count += 1;
        output[count] = try measureAuthoredText(allocator, size, 5);
        count += 1;
        output[count] = try measureAuthoredText(allocator, size, 100);
        count += 1;
    }
    output[count] = try measureSurface(allocator, "surface_1to1_nearest", .{ .width = 320, .height = 180 }, .{ .width = 320, .height = 180 }, .nearest, 1);
    count += 1;
    output[count] = try measureSurface(allocator, "surface_160x90_to_1280x720_nearest", .{ .width = 160, .height = 90 }, .{ .width = 1280, .height = 720 }, .nearest, 1);
    count += 1;
    output[count] = try measureSurface(allocator, "surface_320x180_to_1280x720_nearest", .{ .width = 320, .height = 180 }, .{ .width = 1280, .height = 720 }, .nearest, 1);
    count += 1;
    output[count] = try measureSurface(allocator, "surface_160x90_to_1280x720_linear", .{ .width = 160, .height = 90 }, .{ .width = 1280, .height = 720 }, .linear, 1);
    count += 1;
    output[count] = try measureSurface(allocator, "surface_320x180_to_1280x720_linear", .{ .width = 320, .height = 180 }, .{ .width = 1280, .height = 720 }, .linear, 1);
    count += 1;
    output[count] = try measureSurface(allocator, "surface_world_minimap_ui", .{ .width = 320, .height = 180 }, .{ .width = 1280, .height = 720 }, .nearest, 3);
    count += 1;

    var buffer: [1024]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buffer);
    const out = &writer.interface;
    try out.print("render-benchmark target={s}-{s} warmup_iterations={d} target_pixels={d}\n", .{ @tagName(builtin.os.tag), @tagName(builtin.cpu.arch), warmup_iterations, target_pixels });
    for (output[0..count]) |measurement| try printMeasurement(out, measurement);
    try out.flush();
}

fn measureClear(allocator: std.mem.Allocator, size: Size) !Measurement {
    var counter = CountingAllocator.init(allocator);
    const measured = counter.allocator();
    var canvas = try up.graphics.Canvas.init(measured, size.width, size.height);
    defer canvas.deinit();
    const iterations = iterationsFor(pixels(size));
    for (0..warmup_iterations) |_| canvas.clear(up.core.Color.rgb(12, 24, 36));
    counter.reset();
    var timer = try std.time.Timer.start();
    for (0..iterations) |index| canvas.clear(if (index & 1 == 0) up.core.Color.rgb(12, 24, 36) else up.core.Color.rgb(36, 24, 12));
    const elapsed = timer.read();
    std.mem.doNotOptimizeAway(std.hash.Fnv1a_64.hash(std.mem.sliceAsBytes(canvas.pixels)));
    return .{ .name = "canvas_clear", .width = size.width, .height = size.height, .iterations = iterations, .elapsed_ns = elapsed, .commands_per_iteration = 1, .pixels_per_iteration = pixels(size), .allocation_events = counter.allocation_events, .allocated_bytes = counter.allocated_bytes };
}

fn measureCanvasCopy(allocator: std.mem.Allocator, size: Size) !Measurement {
    var counter = CountingAllocator.init(allocator);
    const measured = counter.allocator();
    var canvas = try up.graphics.Canvas.init(measured, size.width, size.height);
    defer canvas.deinit();
    canvas.clear(up.core.Color.rgb(41, 83, 127));
    const rgba = try measured.alloc(u8, pixels(size) * 4);
    defer measured.free(rgba);
    const iterations = iterationsFor(pixels(size));
    for (0..warmup_iterations) |_| copyCanvasRgba(&canvas, rgba);
    counter.reset();
    var timer = try std.time.Timer.start();
    for (0..iterations) |_| copyCanvasRgba(&canvas, rgba);
    const elapsed = timer.read();
    std.mem.doNotOptimizeAway(std.hash.Fnv1a_64.hash(rgba));
    return .{ .name = "canvas_to_rgba_staging_copy", .width = size.width, .height = size.height, .iterations = iterations, .elapsed_ns = elapsed, .commands_per_iteration = 1, .pixels_per_iteration = pixels(size), .allocation_events = counter.allocation_events, .allocated_bytes = counter.allocated_bytes };
}

fn measureRects(allocator: std.mem.Allocator, size: Size, rect_count: u32, large: bool) !Measurement {
    var counter = CountingAllocator.init(allocator);
    const measured = counter.allocator();
    var canvas = try up.graphics.Canvas.init(measured, size.width, size.height);
    defer canvas.deinit();
    const rect_w: i32 = if (large) @max(1, @as(i32, @intCast(size.width / 2))) else 16;
    const rect_h: i32 = if (large) @max(1, @as(i32, @intCast(size.height / 2))) else 12;
    const iterations = iterationsFor(@as(u64, rect_count) * @as(u64, @intCast(rect_w * rect_h)));
    for (0..warmup_iterations) |_| drawRects(&canvas, rect_count, rect_w, rect_h);
    counter.reset();
    var timer = try std.time.Timer.start();
    for (0..iterations) |_| drawRects(&canvas, rect_count, rect_w, rect_h);
    const elapsed = timer.read();
    std.mem.doNotOptimizeAway(std.hash.Fnv1a_64.hash(std.mem.sliceAsBytes(canvas.pixels)));
    return .{ .name = if (large) "filled_rectangles_large" else "filled_rectangles_small", .width = size.width, .height = size.height, .iterations = iterations, .elapsed_ns = elapsed, .commands_per_iteration = rect_count, .pixels_per_iteration = @as(u64, rect_count) * @as(u64, @intCast(rect_w * rect_h)), .allocation_events = counter.allocation_events, .allocated_bytes = counter.allocated_bytes };
}

fn measureLines(allocator: std.mem.Allocator, size: Size, line_count: u32) !Measurement {
    var counter = CountingAllocator.init(allocator);
    const measured = counter.allocator();
    var canvas = try up.graphics.Canvas.init(measured, size.width, size.height);
    defer canvas.deinit();
    const iterations = iterationsFor(@as(u64, line_count) * size.width);
    for (0..warmup_iterations) |_| drawLines(&canvas, line_count);
    counter.reset();
    var timer = try std.time.Timer.start();
    for (0..iterations) |_| drawLines(&canvas, line_count);
    const elapsed = timer.read();
    std.mem.doNotOptimizeAway(std.hash.Fnv1a_64.hash(std.mem.sliceAsBytes(canvas.pixels)));
    return .{ .name = "lines", .width = size.width, .height = size.height, .iterations = iterations, .elapsed_ns = elapsed, .commands_per_iteration = line_count, .pixels_per_iteration = @as(u64, line_count) * size.width, .allocation_events = counter.allocation_events, .allocated_bytes = counter.allocated_bytes };
}

fn measureCircles(allocator: std.mem.Allocator, size: Size, circle_count: u32) !Measurement {
    var counter = CountingAllocator.init(allocator);
    const measured = counter.allocator();
    var canvas = try up.graphics.Canvas.init(measured, size.width, size.height);
    defer canvas.deinit();
    const iterations = iterationsFor(@as(u64, circle_count) * 17 * 17);
    for (0..warmup_iterations) |_| drawCircles(&canvas, circle_count);
    counter.reset();
    var timer = try std.time.Timer.start();
    for (0..iterations) |_| drawCircles(&canvas, circle_count);
    const elapsed = timer.read();
    std.mem.doNotOptimizeAway(std.hash.Fnv1a_64.hash(std.mem.sliceAsBytes(canvas.pixels)));
    return .{ .name = "filled_circles", .width = size.width, .height = size.height, .iterations = iterations, .elapsed_ns = elapsed, .commands_per_iteration = circle_count, .pixels_per_iteration = @as(u64, circle_count) * 17 * 17, .allocation_events = counter.allocation_events, .allocated_bytes = counter.allocated_bytes };
}

const SpriteAlpha = enum { fully_opaque, translucent };
const SpritePlacement = enum { visible, partially_clipped, offscreen };

fn measureSprites(allocator: std.mem.Allocator, size: Size, sprite_count: u32, alpha: SpriteAlpha, placement: SpritePlacement) !Measurement {
    var counter = CountingAllocator.init(allocator);
    const measured = counter.allocator();
    var canvas = try up.graphics.Canvas.init(measured, size.width, size.height);
    defer canvas.deinit();
    var values: [16 * 16]up.core.Color = undefined;
    populateSprite(&values, alpha);
    const sprite = up.graphics.Sprite{ .width = 16, .height = 16, .pixels = &values };
    const iterations = iterationsFor(@as(u64, sprite_count) * 16 * 16);
    for (0..warmup_iterations) |_| drawSprites(&canvas, sprite, sprite_count, placement);
    counter.reset();
    var timer = try std.time.Timer.start();
    for (0..iterations) |_| drawSprites(&canvas, sprite, sprite_count, placement);
    const elapsed = timer.read();
    std.mem.doNotOptimizeAway(std.hash.Fnv1a_64.hash(std.mem.sliceAsBytes(canvas.pixels)));
    return .{ .name = switch (placement) {
        .visible => if (alpha == .fully_opaque) "sprites_opaque" else "sprites_alpha",
        .partially_clipped => "sprites_alpha_partially_clipped",
        .offscreen => "sprites_opaque_offscreen",
    }, .width = size.width, .height = size.height, .iterations = iterations, .elapsed_ns = elapsed, .commands_per_iteration = sprite_count, .pixels_per_iteration = @as(u64, sprite_count) * 16 * 16, .allocation_events = counter.allocation_events, .allocated_bytes = counter.allocated_bytes };
}

fn measureAtlas(allocator: std.mem.Allocator, size: Size, sprite_count: u32) !Measurement {
    var counter = CountingAllocator.init(allocator);
    const measured = counter.allocator();
    var canvas = try up.graphics.Canvas.init(measured, size.width, size.height);
    defer canvas.deinit();
    const image_pixels = try measured.alloc(up.core.Color, 16 * 16);
    for (image_pixels, 0..) |*pixel, index| pixel.* = .{ .r = @intCast(index % 256), .g = @intCast((index * 3) % 256), .b = @intCast(255 - (index % 256)), .a = 255 };
    var atlas = try up.assets.Atlas.init(measured, .{ .allocator = measured, .width = 16, .height = 16, .pixels = image_pixels }, "render-benchmark", &.{.{ .name = "sprite", .x = 0, .y = 0, .w = 16, .h = 16 }}, &.{});
    defer atlas.deinit();
    const iterations = iterationsFor(@as(u64, sprite_count) * 16 * 16);
    for (0..warmup_iterations) |_| drawAtlas(&canvas, atlas, sprite_count);
    counter.reset();
    var timer = try std.time.Timer.start();
    for (0..iterations) |_| drawAtlas(&canvas, atlas, sprite_count);
    const elapsed = timer.read();
    std.mem.doNotOptimizeAway(std.hash.Fnv1a_64.hash(std.mem.sliceAsBytes(canvas.pixels)));
    return .{ .name = "atlas_sprites_tinted", .width = size.width, .height = size.height, .iterations = iterations, .elapsed_ns = elapsed, .commands_per_iteration = sprite_count, .pixels_per_iteration = @as(u64, sprite_count) * 16 * 16, .allocation_events = counter.allocation_events, .allocated_bytes = counter.allocated_bytes };
}

fn measureBuiltinText(allocator: std.mem.Allocator, size: Size, strings: u32) !Measurement {
    var counter = CountingAllocator.init(allocator);
    const measured = counter.allocator();
    var canvas = try up.graphics.Canvas.init(measured, size.width, size.height);
    defer canvas.deinit();
    const iterations = iterationsFor(@as(u64, strings) * 5 * 7 * "HUD 0123".len);
    for (0..warmup_iterations) |_| drawBuiltinText(&canvas, strings);
    counter.reset();
    var timer = try std.time.Timer.start();
    for (0..iterations) |_| drawBuiltinText(&canvas, strings);
    const elapsed = timer.read();
    std.mem.doNotOptimizeAway(std.hash.Fnv1a_64.hash(std.mem.sliceAsBytes(canvas.pixels)));
    return .{ .name = if (strings == 5) "builtin_text_hud" else "builtin_text_heavy", .width = size.width, .height = size.height, .iterations = iterations, .elapsed_ns = elapsed, .commands_per_iteration = strings, .pixels_per_iteration = @as(u64, strings) * 5 * 7 * "HUD 0123".len, .allocation_events = counter.allocation_events, .allocated_bytes = counter.allocated_bytes };
}

fn measureAuthoredText(allocator: std.mem.Allocator, size: Size, strings: u32) !Measurement {
    var counter = CountingAllocator.init(allocator);
    const measured = counter.allocator();
    var canvas = try up.graphics.Canvas.init(measured, size.width, size.height);
    defer canvas.deinit();
    const font_bytes = try std.fs.cwd().readFileAlloc(measured, "dogfood/neon-siege/assets/neon-siege.ttf", 4 * 1024 * 1024);
    defer measured.free(font_bytes);
    var font = try up.assets.Font.decodeTrueType(measured, font_bytes, .{});
    defer font.deinit();
    const iterations = iterationsFor(@as(u64, strings) * 10 * 20);
    for (0..warmup_iterations) |_| drawAuthoredText(&canvas, &font, strings);
    counter.reset();
    var timer = try std.time.Timer.start();
    for (0..iterations) |_| drawAuthoredText(&canvas, &font, strings);
    const elapsed = timer.read();
    std.mem.doNotOptimizeAway(std.hash.Fnv1a_64.hash(std.mem.sliceAsBytes(canvas.pixels)));
    return .{ .name = if (strings == 5) "authored_text_hud" else "authored_text_heavy", .width = size.width, .height = size.height, .iterations = iterations, .elapsed_ns = elapsed, .commands_per_iteration = strings, .pixels_per_iteration = @as(u64, strings) * 10 * 20, .allocation_events = counter.allocation_events, .allocated_bytes = counter.allocated_bytes };
}

fn measureSurface(allocator: std.mem.Allocator, name: []const u8, source_size: Size, destination_size: Size, filter: up.graphics.SurfaceFilter, surface_count: u32) !Measurement {
    var counter = CountingAllocator.init(allocator);
    const measured = counter.allocator();
    var canvas = try up.graphics.Canvas.init(measured, destination_size.width, destination_size.height);
    defer canvas.deinit();
    var first = try up.graphics.RenderSurface.init(measured, source_size.width, source_size.height);
    defer first.deinit();
    var second = try up.graphics.RenderSurface.init(measured, source_size.width, source_size.height);
    defer second.deinit();
    var third = try up.graphics.RenderSurface.init(measured, source_size.width, source_size.height);
    defer third.deinit();
    first.canvas().clear(up.core.Color.rgb(40, 80, 120));
    second.canvas().clear(up.core.Color.rgb(120, 80, 40));
    third.canvas().clear(up.core.Color.rgb(80, 120, 40));
    const pixels_per_iteration = if (surface_count == 3)
        pixels(destination_size) + @as(u64, destination_size.width / 5) * (destination_size.height / 5) + pixels(source_size)
    else
        pixels(destination_size) * surface_count;
    const iterations = iterationsFor(pixels_per_iteration);
    for (0..warmup_iterations) |_| try drawSurfaces(&canvas, &first, &second, &third, filter, surface_count);
    counter.reset();
    var timer = try std.time.Timer.start();
    for (0..iterations) |_| try drawSurfaces(&canvas, &first, &second, &third, filter, surface_count);
    const elapsed = timer.read();
    std.mem.doNotOptimizeAway(std.hash.Fnv1a_64.hash(std.mem.sliceAsBytes(canvas.pixels)));
    return .{ .name = name, .width = destination_size.width, .height = destination_size.height, .iterations = iterations, .elapsed_ns = elapsed, .commands_per_iteration = surface_count, .pixels_per_iteration = pixels_per_iteration, .allocation_events = counter.allocation_events, .allocated_bytes = counter.allocated_bytes };
}

fn drawRects(canvas: *up.graphics.Canvas, count: u32, width: i32, height: i32) void {
    var index: u32 = 0;
    while (index < count) : (index += 1) canvas.fillRect(position(canvas.width, index, 17), position(canvas.height, index, 11), width, height, up.core.Color.rgb(70, 150, 220));
}

fn drawLines(canvas: *up.graphics.Canvas, count: u32) void {
    var index: u32 = 0;
    while (index < count) : (index += 1) canvas.line(0, position(canvas.height, index, 13), @intCast(canvas.width - 1), position(canvas.height, index + 7, 19), up.core.Color.rgb(240, 190, 70));
}

fn drawCircles(canvas: *up.graphics.Canvas, count: u32) void {
    var index: u32 = 0;
    while (index < count) : (index += 1) canvas.fillCircle(position(canvas.width, index, 17), position(canvas.height, index, 13), 8, up.core.Color.rgb(120, 220, 150));
}

fn drawSprites(canvas: *up.graphics.Canvas, sprite: up.graphics.Sprite, count: u32, placement: SpritePlacement) void {
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const x = switch (placement) {
            .visible => position(canvas.width, index, 19),
            .partially_clipped => -8,
            .offscreen => -32 - @as(i32, @intCast(index % 32)),
        };
        const y = position(canvas.height, index, 23);
        canvas.drawSprite(sprite, x, y);
    }
}

fn drawAtlas(canvas: *up.graphics.Canvas, atlas: up.assets.Atlas, count: u32) void {
    var index: u32 = 0;
    while (index < count) : (index += 1) canvas.drawAtlasFrame(atlas, .{ .index = 0 }, position(canvas.width, index, 19), position(canvas.height, index, 23), .{ .tint = up.core.Color.rgb(160, 210, 255) });
}

fn drawBuiltinText(canvas: *up.graphics.Canvas, count: u32) void {
    var index: u32 = 0;
    while (index < count) : (index += 1) canvas.drawText("HUD 0123", position(canvas.width, index, 31), position(canvas.height, index, 17), up.core.Color.white);
}

fn drawAuthoredText(canvas: *up.graphics.Canvas, font: *const up.assets.Font, count: u32) void {
    var index: u32 = 0;
    while (index < count) : (index += 1) font.drawText(canvas, "Neon Siege", position(canvas.width, index, 37), position(canvas.height, index, 23), up.core.Color.white);
}

fn drawSurfaces(canvas: *up.graphics.Canvas, first: *const up.graphics.RenderSurface, second: *const up.graphics.RenderSurface, third: *const up.graphics.RenderSurface, filter: up.graphics.SurfaceFilter, count: u32) !void {
    try canvas.drawSurface(first, .{ .x = 0, .y = 0, .width = canvas.width, .height = canvas.height, .filter = filter });
    if (count > 1) try canvas.drawSurface(second, .{ .x = 8, .y = 8, .width = canvas.width / 5, .height = canvas.height / 5, .filter = filter });
    if (count > 2) try canvas.drawSurface(third, .{ .x = 16, .y = @intCast(canvas.height - third.height() - 8), .width = third.width(), .height = third.height(), .filter = filter });
}

fn populateSprite(values: []up.core.Color, alpha: SpriteAlpha) void {
    for (values, 0..) |*value, index| value.* = .{ .r = @intCast((index * 13) % 256), .g = @intCast((index * 29) % 256), .b = @intCast((index * 47) % 256), .a = if (alpha == .fully_opaque) 255 else 128 };
}

fn copyCanvasRgba(canvas: *const up.graphics.Canvas, output: []u8) void {
    for (canvas.pixels, 0..) |pixel, index| {
        const offset = index * 4;
        output[offset] = pixel.r;
        output[offset + 1] = pixel.g;
        output[offset + 2] = pixel.b;
        output[offset + 3] = pixel.a;
    }
}

fn position(bound: u32, index: u32, step: u32) i32 {
    return @intCast((@as(u64, index) * step) % bound);
}

fn pixels(size: Size) u64 {
    return @as(u64, size.width) * size.height;
}

fn iterationsFor(pixels_per_iteration: u64) u32 {
    const value = std.math.divCeil(u64, target_pixels, @max(@as(u64, 1), pixels_per_iteration)) catch unreachable;
    return @intCast(std.math.clamp(value, @as(u64, 8), @as(u64, 8_192)));
}

fn printMeasurement(out: *std.Io.Writer, value: Measurement) !void {
    const average_ns = value.elapsed_ns / value.iterations;
    const mpixels_per_second = if (average_ns == 0) 0 else (@as(f64, @floatFromInt(value.pixels_per_iteration)) * 1_000.0) / @as(f64, @floatFromInt(average_ns));
    try out.print("{s} {d}x{d} iterations={d} total_ns={d} average_ns={d} commands={d} pixels={d} mpixels_per_s={d:.2} allocations={d} allocated_bytes={d}\n", .{ value.name, value.width, value.height, value.iterations, value.elapsed_ns, average_ns, value.commands_per_iteration, value.pixels_per_iteration, mpixels_per_second, value.allocation_events, value.allocated_bytes });
}

test "iteration count stays bounded for every published canvas size" {
    for (sizes) |size| try std.testing.expect(iterationsFor(pixels(size)) >= 8);
}
