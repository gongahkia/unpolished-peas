//! Explicit opt-in composition. Borrow sources until presentation; synchronize
//! by uploading their latest pixels every submitted frame, without dirty flags.
const std = @import("std");
const drawing = @import("canvas.zig");
const Color = @import("color.zig").Color;
const Canvas = drawing.Canvas;
const RenderSurface = drawing.RenderSurface;
var next_owner: u64 = 1;

pub const SurfaceCompositor = struct {
    pub const max_layers = 32;
    pub const max_draws = 128;
    pub const max_dimension = 4096;
    pub const Config = struct {
        layers: usize = 8,
        draws: usize = 32,
        max_source_bytes: usize = 16 * 1024 * 1024,
    };
    pub const Layer = struct { owner: u64, index: u16, generation: u32 };
    pub const Options = struct {
        surface: drawing.SurfaceDrawOptions,
        clip: ?drawing.ClipRect = null,
        blend: drawing.BlendMode = .alpha,
    };
    pub const Slot = struct {
        source: ?*const RenderSurface = null,
        generation: u32 = 1,
        width: u32 = 0,
        height: u32 = 0,
    };
    pub const Draw = struct {
        /// Null denotes the host Canvas at this precise position in the queue.
        layer: ?Layer,
        options: Options,
    };

    allocator: std.mem.Allocator,
    owner: u64,
    slots: []Slot,
    draws: []Draw,
    count: usize = 0,
    clear_color: Color = Color.black,
    source_bytes: usize = 0,
    max_source_bytes: usize,
    canvas_queued: bool = false,

    /// Allocates bounded metadata only. This object and its sources are used
    /// on the game thread; they must outlive a queued Renderer2D submission.
    pub fn init(allocator: std.mem.Allocator, config: Config) !SurfaceCompositor {
        if (config.layers == 0 or config.layers > max_layers or config.draws == 0 or config.draws > max_draws or config.max_source_bytes == 0 or config.max_source_bytes > 64 * 1024 * 1024) return error.InvalidSurfaceCompositorConfig;
        if (next_owner == std.math.maxInt(u64)) return error.SurfaceCompositorIdentityExhausted;
        const slots = try allocator.alloc(Slot, config.layers);
        errdefer allocator.free(slots);
        const draws = try allocator.alloc(Draw, config.draws);
        @memset(slots, .{});
        const owner = next_owner;
        next_owner += 1;
        return .{ .allocator = allocator, .owner = owner, .slots = slots, .draws = draws, .max_source_bytes = config.max_source_bytes };
    }
    /// Release after the last frame using this compositor. Host textures are
    /// reclaimed on the next presentation without it, or on host shutdown.
    pub fn deinit(self: *SurfaceCompositor) void {
        self.allocator.free(self.slots);
        self.allocator.free(self.draws);
        self.* = undefined;
    }
    pub fn retain(self: *SurfaceCompositor, source: *const RenderSurface) !Layer {
        const width = source.width();
        const height = source.height();
        if (width == 0 or height == 0 or width > max_dimension or height > max_dimension or source.target.pixels.len != @as(usize, width) * height) return error.InvalidCompositionSource;
        const bytes = @as(usize, width) * height * @sizeOf(Color);
        if (bytes > self.max_source_bytes - self.source_bytes) return error.CompositionSourceBudgetExceeded;
        for (self.slots, 0..) |*slot, index| if (slot.source == null and slot.generation != 0) {
            slot.source = source;
            slot.width = width;
            slot.height = height;
            self.source_bytes += bytes;
            return .{ .owner = self.owner, .index = @intCast(index), .generation = slot.generation };
        };
        return error.CompositionLayerLimit;
    }
    pub fn release(self: *SurfaceCompositor, layer: Layer) !void {
        _ = try self.getSurface(layer);
        const slot = &self.slots[layer.index];
        self.source_bytes -= @as(usize, slot.width) * slot.height * @sizeOf(Color);
        slot.source = null;
        // Retire a slot rather than resurrect a stale handle after wrapping.
        slot.generation = if (slot.generation == std.math.maxInt(u32)) 0 else slot.generation + 1;
    }
    /// Raw pixel writes are visible without explicit invalidation. Resizing or
    /// destroying a retained source is forbidden; release and retain a new one.
    pub fn getSurface(self: *const SurfaceCompositor, layer: Layer) !*const RenderSurface {
        if (layer.owner != self.owner or layer.index >= self.slots.len) return error.StaleCompositionLayer;
        const slot = self.slots[layer.index];
        if (layer.generation != slot.generation) return error.StaleCompositionLayer;
        const result = slot.source orelse return error.StaleCompositionLayer;
        if (result.width() != slot.width or result.height() != slot.height or result.target.pixels.len != @as(usize, slot.width) * slot.height) return error.CompositionSourceResized;
        return result;
    }
    /// The prototype produces an opaque final frame. Invalid input leaves the
    /// existing queue untouched. This retains layers and resets draw metadata.
    pub fn beginFrame(self: *SurfaceCompositor, clear_color: Color) !void {
        if (clear_color.a != 255) return error.TransparentCompositionTargetUnsupported;
        self.count = 0;
        self.canvas_queued = false;
        self.clear_color = clear_color;
    }
    pub fn drawLayer(self: *SurfaceCompositor, layer: Layer, options: Options) !void {
        _ = try self.getSurface(layer);
        try validateOptions(options);
        if (self.count == self.draws.len) return error.CompositionDrawLimit;
        self.draws[self.count] = .{ .layer = layer, .options = options };
        self.count += 1;
    }
    /// Inserts the current host Canvas exactly once. Draw into that Canvas
    /// normally; use its opt-in preserve_alpha flag for transparent foregrounds.
    /// It is sampled at presentation, after the game's draw callback finishes.
    pub fn drawCanvas(self: *SurfaceCompositor) !void {
        if (self.canvas_queued) return error.CompositionCanvasAlreadyQueued;
        if (self.count == self.draws.len) return error.CompositionDrawLimit;
        self.draws[self.count] = .{ .layer = null, .options = .{ .surface = .{ .x = 0, .y = 0, .width = 0, .height = 0 } } };
        self.count += 1;
        self.canvas_queued = true;
    }
    pub fn commands(self: *const SurfaceCompositor) []const Draw {
        return self.draws[0..self.count];
    }
    pub fn validate(self: *const SurfaceCompositor, canvas: *const Canvas) !void {
        if (canvas.width > max_dimension or canvas.height > max_dimension) return error.CompositionTargetTooLarge;
        if (self.clear_color.a != 255) return error.TransparentCompositionTargetUnsupported;
        for (self.commands()) |draw| if (draw.layer) |layer| {
            const surface = try self.getSurface(layer);
            try validateOptions(draw.options);
            if (surface.target.pixels.ptr == canvas.pixels.ptr) return error.CompositionFeedbackUnsupported;
        };
    }
    /// Deterministic headless reference. Destination must not alias any source
    /// or the queued Canvas. Clip/blend state is restored and drawing allocates
    /// nothing. GPU sampling/blending can differ by documented rounding units.
    pub fn drawCpu(self: *const SurfaceCompositor, destination: *Canvas, canvas: *const Canvas) !void {
        try self.validate(canvas);
        if (destination.width != canvas.width or destination.height != canvas.height) return error.CompositionTargetSizeMismatch;
        if (self.canvas_queued and destination.pixels.ptr == canvas.pixels.ptr) return error.CompositionFeedbackUnsupported;
        for (self.commands()) |draw| if (draw.layer) |layer| {
            if ((try self.getSurface(layer)).target.pixels.ptr == destination.pixels.ptr) return error.CompositionFeedbackUnsupported;
        };
        const previous_clip = destination.clip;
        const previous_blend = destination.blend;
        defer {
            destination.clip = previous_clip;
            destination.blend = previous_blend;
        }
        destination.clip = null;
        destination.blend = .alpha;
        destination.clear(self.clear_color);
        for (self.commands()) |draw| {
            destination.clip = draw.options.clip;
            if (draw.layer) |layer| try destination.drawSurface(try self.getSurface(layer), draw.options.surface) else {
                const borrowed = RenderSurface{ .target = canvas.* };
                try destination.drawSurface(&borrowed, .{ .x = 0, .y = 0, .width = canvas.width, .height = canvas.height });
            }
        }
    }
    fn validateOptions(options: Options) !void {
        if (options.blend != .alpha) return error.CompositionBlendUnsupported;
        const rect = options.surface;
        if (rect.width == 0 or rect.height == 0 or rect.width > 65535 or rect.height > 65535) return error.InvalidCompositionRectangle;
        _ = std.math.add(i32, rect.x, @intCast(rect.width)) catch return error.InvalidCompositionRectangle;
        _ = std.math.add(i32, rect.y, @intCast(rect.height)) catch return error.InvalidCompositionRectangle;
        if (options.clip) |clip| {
            if (clip.w <= 0 or clip.h <= 0) return error.InvalidCompositionClip;
            _ = std.math.add(i32, clip.x, clip.w) catch return error.InvalidCompositionClip;
            _ = std.math.add(i32, clip.y, clip.h) catch return error.InvalidCompositionClip;
        }
    }
};

test "ordered CPU reference observes raw mutations, tint, clipping and stale handles" {
    var layer = try RenderSurface.init(std.testing.allocator, 2, 1);
    defer layer.deinit();
    var comp = try SurfaceCompositor.init(std.testing.allocator, .{ .layers = 1, .draws = 4 });
    defer comp.deinit();
    var foreground = try Canvas.init(std.testing.allocator, 4, 2);
    defer foreground.deinit();
    var output = try Canvas.init(std.testing.allocator, 4, 2);
    defer output.deinit();
    const handle = try comp.retain(&layer);
    try comp.beginFrame(Color.rgb(2, 4, 6));
    try comp.drawLayer(handle, .{ .surface = .{ .x = 0, .y = 0, .width = 4, .height = 2, .tint = Color.rgb(128, 255, 255) }, .clip = .{ .x = 1, .y = 0, .w = 2, .h = 2 } });
    try comp.drawCanvas();
    layer.canvas().pixels[0] = Color.rgb(200, 40, 60);
    layer.canvas().pixels[1] = Color.rgb(20, 80, 120);
    foreground.pixel(1, 0, Color.white);
    try comp.drawCpu(&output, &foreground);
    try std.testing.expectEqual(Color.white, output.get(1, 0).?);
    try std.testing.expectEqual(Color.rgb(10, 80, 120), output.get(2, 1).?);
    try std.testing.expectEqual(Color.rgb(2, 4, 6), output.get(0, 1).?);
    try std.testing.expectError(error.CompositionBlendUnsupported, comp.drawLayer(handle, .{ .surface = .{ .x = 0, .y = 0, .width = 1, .height = 1 }, .blend = .additive }));
    try std.testing.expectEqual(@as(usize, 2), comp.count);
    try comp.release(handle);
    try std.testing.expectError(error.StaleCompositionLayer, comp.drawCpu(&output, &foreground));
    const fresh = try comp.retain(&layer);
    try std.testing.expect(fresh.generation != handle.generation);
}
fn allocationProbe(allocator: std.mem.Allocator) !void {
    var comp = try SurfaceCompositor.init(allocator, .{});
    defer comp.deinit();
}
test "compositor partial initialization releases metadata on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{});
}

test "bounds and invalid submissions leave queue and source budget intact" {
    const allocator = std.testing.allocator;
    var source = try RenderSurface.init(allocator, 2, 2);
    defer source.deinit();
    var comp = try SurfaceCompositor.init(allocator, .{ .layers = 1, .draws = 1, .max_source_bytes = 16 });
    defer comp.deinit();
    var other = try SurfaceCompositor.init(allocator, .{ .layers = 1, .draws = 1 });
    defer other.deinit();
    const handle = try comp.retain(&source);
    try std.testing.expectError(error.CompositionSourceBudgetExceeded, comp.retain(&source));
    try std.testing.expectEqual(@as(usize, 16), comp.source_bytes);
    try std.testing.expectError(error.StaleCompositionLayer, other.release(handle));
    try std.testing.expectError(error.InvalidCompositionRectangle, comp.drawLayer(handle, .{ .surface = .{ .x = 0, .y = 0, .width = 0, .height = 1 } }));
    try std.testing.expectError(error.InvalidCompositionRectangle, comp.drawLayer(handle, .{ .surface = .{ .x = std.math.maxInt(i32), .y = 0, .width = 1, .height = 1 } }));
    try std.testing.expectError(error.InvalidCompositionRectangle, comp.drawLayer(handle, .{ .surface = .{ .x = 0, .y = 0, .width = 65536, .height = 1 } }));
    try std.testing.expectError(error.InvalidCompositionClip, comp.drawLayer(handle, .{ .surface = .{ .x = 0, .y = 0, .width = 1, .height = 1 }, .clip = .{ .x = 0, .y = 0, .w = -1, .h = 1 } }));
    try std.testing.expectEqual(@as(usize, 0), comp.count);
    try comp.drawCanvas();
    try std.testing.expectError(error.TransparentCompositionTargetUnsupported, comp.beginFrame(Color.transparent));
    try std.testing.expectEqual(@as(usize, 1), comp.count);
    try std.testing.expectError(error.CompositionCanvasAlreadyQueued, comp.drawCanvas());
    try std.testing.expectError(error.CompositionDrawLimit, comp.drawLayer(handle, .{ .surface = .{ .x = 0, .y = 0, .width = 1, .height = 1 } }));
    source.target.width = 1;
    try std.testing.expectError(error.CompositionSourceResized, comp.getSurface(handle));
    source.target.width = 2;
    try comp.release(handle);
    try std.testing.expectEqual(@as(usize, 0), comp.source_bytes);
    try std.testing.expectError(error.StaleCompositionLayer, comp.release(handle));
    const fresh = try comp.retain(&source);
    try std.testing.expect(fresh.generation != handle.generation);
}

test "prepared CPU composition allocates nothing, restores state and rejects feedback" {
    const allocator = std.testing.allocator;
    var source = try RenderSurface.init(allocator, 2, 2);
    defer source.deinit();
    var foreground = try Canvas.init(allocator, 2, 2);
    defer foreground.deinit();
    var output = try Canvas.init(allocator, 2, 2);
    defer output.deinit();
    var metadata: [4096]u8 = undefined;
    var bounded = std.heap.FixedBufferAllocator.init(&metadata);
    var comp = try SurfaceCompositor.init(bounded.allocator(), .{ .layers = 1, .draws = 2 });
    defer comp.deinit();
    const allocated = bounded.end_index;
    const handle = try comp.retain(&source);
    source.canvas().clear(Color.rgb(255, 0, 0));
    foreground.clear(Color.transparent);
    output.clip = .{ .x = 1, .y = 1, .w = 1, .h = 1 };
    output.blend = .additive;
    const saved_clip = output.clip;
    for (0..32) |_| {
        try comp.beginFrame(Color.black);
        try comp.drawLayer(handle, .{ .surface = .{ .x = 0, .y = 0, .width = 2, .height = 2 } });
        try comp.drawCanvas();
        try comp.drawCpu(&output, &foreground);
        // get() observes the restored clip; inspect storage outside that clip.
        try std.testing.expectEqual(Color.rgb(255, 0, 0), output.pixels[0]);
        try std.testing.expectEqual(saved_clip, output.clip);
        try std.testing.expectEqual(drawing.BlendMode.additive, output.blend);
    }
    try std.testing.expectEqual(allocated, bounded.end_index);
    try std.testing.expectError(error.CompositionFeedbackUnsupported, comp.drawCpu(&foreground, &foreground));
    try std.testing.expectError(error.CompositionFeedbackUnsupported, comp.drawCpu(source.canvas(), &foreground));
    try std.testing.expectError(error.CompositionFeedbackUnsupported, comp.validate(source.canvas()));
}
