const std = @import("std");
const Camera2D = @import("camera.zig").Camera2D;
const CameraCanvas = @import("camera_canvas.zig").CameraCanvas;
const Canvas = @import("canvas.zig").Canvas;
const ClipRect = @import("canvas.zig").ClipRect;
const Color = @import("color.zig").Color;
const Vec2 = @import("math.zig").Vec2;
const Rect = @import("math.zig").Rect;
const CommandBuffer = @import("render.zig").CommandBuffer;
const HeadlessRenderer = @import("render.zig").HeadlessRenderer;

pub const Config = struct {
    max_lights: u16 = 32,
    max_occluders: u16 = 64,
};

pub const Light = struct {
    position: Vec2,
    radius: f32,
    color: Color = Color.white,
    intensity: f32 = 1,
};

pub const Occluder = struct {
    bounds: Rect,
};

pub const RenderPath = enum {
    gpu_primitives,
    headless_fallback,
};

pub const Metrics = struct {
    path: RenderPath,
    lights: u16,
    occluders: u16,
    lit_pixels: u32,
};

pub const Pipeline = struct {
    allocator: std.mem.Allocator,
    lights: []Light,
    occluders: []Occluder,
    light_len: u16 = 0,
    occluder_len: u16 = 0,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Pipeline {
        if (config.max_lights == 0) return error.InvalidLightingConfig;
        const lights = try allocator.alloc(Light, config.max_lights);
        errdefer allocator.free(lights);
        const occluders = try allocator.alloc(Occluder, config.max_occluders);
        return .{ .allocator = allocator, .lights = lights, .occluders = occluders };
    }

    pub fn deinit(self: *Pipeline) void {
        self.allocator.free(self.lights);
        self.allocator.free(self.occluders);
        self.* = undefined;
    }

    pub fn clear(self: *Pipeline) void {
        self.light_len = 0;
        self.occluder_len = 0;
    }

    pub fn addLight(self: *Pipeline, light: Light) !void {
        if (!validLight(light)) return error.InvalidLightBounds;
        if (self.light_len == self.lights.len) return error.TooManyLights;
        self.lights[self.light_len] = light;
        self.light_len += 1;
    }

    pub fn addOccluder(self: *Pipeline, occluder: Occluder) !void {
        if (!validRect(occluder.bounds)) return error.InvalidOccluderBounds;
        if (self.occluder_len == self.occluders.len) return error.TooManyOccluders;
        self.occluders[self.occluder_len] = occluder;
        self.occluder_len += 1;
    }

    pub fn lightItems(self: *const Pipeline) []const Light {
        return self.lights[0..self.light_len];
    }

    pub fn occluderItems(self: *const Pipeline) []const Occluder {
        return self.occluders[0..self.occluder_len];
    }

    pub fn preferredPath(gpu_primitives_supported: bool) RenderPath {
        return if (gpu_primitives_supported) .gpu_primitives else .headless_fallback;
    }

    pub fn render(self: *const Pipeline, target: CameraCanvas) Metrics {
        const previous_blend = target.canvas.setBlend(.additive);
        defer _ = target.canvas.setBlend(previous_blend);
        const clip = clipFor(target.camera, target.canvas_size);
        const previous_clip = target.canvas.pushClip(clip);
        defer target.canvas.restoreClip(previous_clip);
        return self.writePixels(target.camera, target.canvas_size, .headless_fallback, target.canvas, null) catch unreachable;
    }

    pub fn append(self: *const Pipeline, commands: *CommandBuffer, camera: *const Camera2D, canvas_size: Vec2) !Metrics {
        try commands.append(.{ .push_clip = clipFor(camera, canvas_size) });
        errdefer _ = commands.append(.pop_clip) catch {};
        try commands.append(.{ .push_blend = .additive });
        errdefer _ = commands.append(.pop_blend) catch {};
        const metrics = try self.writePixels(camera, canvas_size, .gpu_primitives, null, commands);
        try commands.append(.pop_blend);
        try commands.append(.pop_clip);
        return metrics;
    }

    fn writePixels(self: *const Pipeline, camera: *const Camera2D, canvas_size: Vec2, path: RenderPath, canvas: ?*Canvas, commands: ?*CommandBuffer) !Metrics {
        const clip = clipFor(camera, canvas_size);
        var lit_pixels: u32 = 0;
        var y = clip.y;
        while (y < clip.y + clip.h) : (y += 1) {
            var x = clip.x;
            while (x < clip.x + clip.w) : (x += 1) {
                const world = camera.canvasToWorld(.{ .x = @as(f32, @floatFromInt(x)) + 0.5, .y = @as(f32, @floatFromInt(y)) + 0.5 }, canvas_size);
                const color = self.colorAt(world);
                if (color.a == 0) continue;
                lit_pixels += 1;
                if (canvas) |value| value.pixel(x, y, color) else try commands.?.append(.{ .rect = .{ .x = x, .y = y, .w = 1, .h = 1, .color = color } });
            }
        }
        return .{ .path = path, .lights = self.light_len, .occluders = self.occluder_len, .lit_pixels = lit_pixels };
    }

    fn colorAt(self: *const Pipeline, point: Vec2) Color {
        var red: f32 = 0;
        var green: f32 = 0;
        var blue: f32 = 0;
        for (self.lightItems()) |light| {
            const distance = point.sub(light.position).len();
            if (distance >= light.radius or blocked(light.position, point, self.occluderItems())) continue;
            const strength = (1 - distance / light.radius) * light.intensity * @as(f32, @floatFromInt(light.color.a)) / 255;
            red += @as(f32, @floatFromInt(light.color.r)) * strength;
            green += @as(f32, @floatFromInt(light.color.g)) * strength;
            blue += @as(f32, @floatFromInt(light.color.b)) * strength;
        }
        if (red == 0 and green == 0 and blue == 0) return Color.transparent;
        return .{
            .r = channel(red),
            .g = channel(green),
            .b = channel(blue),
            .a = 255,
        };
    }
};

fn validLight(light: Light) bool {
    return std.math.isFinite(light.position.x) and std.math.isFinite(light.position.y) and std.math.isFinite(light.radius) and std.math.isFinite(light.intensity) and light.radius > 0 and light.intensity >= 0 and light.intensity <= 1;
}

fn validRect(rect: Rect) bool {
    return std.math.isFinite(rect.x) and std.math.isFinite(rect.y) and std.math.isFinite(rect.w) and std.math.isFinite(rect.h) and rect.w > 0 and rect.h > 0;
}

fn clipFor(camera: *const Camera2D, canvas_size: Vec2) ClipRect {
    const viewport = camera.canvasViewport(canvas_size);
    const max_x: i32 = @intFromFloat(@floor(canvas_size.x));
    const max_y: i32 = @intFromFloat(@floor(canvas_size.y));
    const x = @max(0, @as(i32, @intFromFloat(@floor(viewport.x))));
    const y = @max(0, @as(i32, @intFromFloat(@floor(viewport.y))));
    const right = @min(max_x, @as(i32, @intFromFloat(@ceil(viewport.x + viewport.w))));
    const bottom = @min(max_y, @as(i32, @intFromFloat(@ceil(viewport.y + viewport.h))));
    return .{ .x = x, .y = y, .w = @max(0, right - x), .h = @max(0, bottom - y) };
}

fn blocked(from: Vec2, to: Vec2, occluders: []const Occluder) bool {
    for (occluders) |occluder| if (segmentIntersectsRect(from, to, occluder.bounds)) return true;
    return false;
}

fn segmentIntersectsRect(from: Vec2, to: Vec2, rect: Rect) bool {
    const delta = to.sub(from);
    var entry: f32 = 0;
    var exit: f32 = 1;
    if (!clipAxis(from.x, delta.x, rect.x, rect.x + rect.w, &entry, &exit)) return false;
    if (!clipAxis(from.y, delta.y, rect.y, rect.y + rect.h, &entry, &exit)) return false;
    return exit > 0.0001 and entry < 0.9999;
}

fn clipAxis(origin: f32, delta: f32, minimum: f32, maximum: f32, entry: *f32, exit: *f32) bool {
    if (@abs(delta) < 0.000001) return origin >= minimum and origin <= maximum;
    var first = (minimum - origin) / delta;
    var last = (maximum - origin) / delta;
    if (first > last) std.mem.swap(f32, &first, &last);
    entry.* = @max(entry.*, first);
    exit.* = @min(exit.*, last);
    return entry.* <= exit.*;
}

fn channel(value: f32) u8 {
    return @intFromFloat(@round(@min(@as(f32, 255), value)));
}

test "lighting validates bounded light and occluder input" {
    try std.testing.expectError(error.InvalidLightingConfig, Pipeline.init(std.testing.allocator, .{ .max_lights = 0 }));
    var pipeline = try Pipeline.init(std.testing.allocator, .{ .max_lights = 1, .max_occluders = 1 });
    defer pipeline.deinit();
    try std.testing.expectError(error.InvalidLightBounds, pipeline.addLight(.{ .position = .{ .x = std.math.inf(f32) }, .radius = 1 }));
    try std.testing.expectError(error.InvalidLightBounds, pipeline.addLight(.{ .position = .{}, .radius = 0 }));
    try std.testing.expectError(error.InvalidLightBounds, pipeline.addLight(.{ .position = .{}, .radius = 1, .intensity = 1.1 }));
    try pipeline.addLight(.{ .position = .{}, .radius = 1 });
    try std.testing.expectError(error.TooManyLights, pipeline.addLight(.{ .position = .{}, .radius = 1 }));
    try std.testing.expectError(error.InvalidOccluderBounds, pipeline.addOccluder(.{ .bounds = .init(0, 0, 0, 1) }));
    try pipeline.addOccluder(.{ .bounds = .init(0, 0, 1, 1) });
    try std.testing.expectError(error.TooManyOccluders, pipeline.addOccluder(.{ .bounds = .init(2, 0, 1, 1) }));
}

test "lighting camera output golden and occlusion" {
    var pipeline = try Pipeline.init(std.testing.allocator, .{});
    defer pipeline.deinit();
    try pipeline.addLight(.{ .position = .{ .x = 10.5, .y = 5.5 }, .radius = 2, .color = .rgb(255, 128, 0) });
    var canvas = try @import("canvas.zig").Canvas.init(std.testing.allocator, 4, 2);
    defer canvas.deinit();
    canvas.clear(Color.black);
    var camera = Camera2D{ .position = .{ .x = 10, .y = 5 } };
    const metrics = pipeline.render(.init(&canvas, &camera));
    const expected = [_]Color{
        Color.black, .rgb(75, 37, 0),  .rgb(128, 64, 0),  .rgb(75, 37, 0),
        Color.black, .rgb(128, 64, 0), .rgb(255, 128, 0), .rgb(128, 64, 0),
    };
    try std.testing.expectEqualSlices(Color, &expected, canvas.pixels);
    try std.testing.expectEqual(@as(u32, 6), metrics.lit_pixels);

    pipeline.clear();
    try pipeline.addLight(.{ .position = .{ .x = -0.5, .y = 0.5 }, .radius = 5, .color = .rgb(255, 0, 0) });
    try pipeline.addOccluder(.{ .bounds = .init(0.25, 0, 0.5, 1) });
    var occluded = try @import("canvas.zig").Canvas.init(std.testing.allocator, 5, 1);
    defer occluded.deinit();
    occluded.clear(Color.black);
    var occlusion_camera = Camera2D{ .position = .{ .x = 0.5, .y = 0.5 } };
    _ = pipeline.render(.init(&occluded, &occlusion_camera));
    try std.testing.expectEqual(Color.rgb(204, 0, 0), occluded.get(0, 0).?);
    try std.testing.expectEqual(Color.rgb(255, 0, 0), occluded.get(1, 0).?);
    try std.testing.expectEqual(Color.black, occluded.get(2, 0).?);
    try std.testing.expectEqual(Color.black, occluded.get(4, 0).?);
}

test "lighting command pass matches headless fallback" {
    var pipeline = try Pipeline.init(std.testing.allocator, .{});
    defer pipeline.deinit();
    try pipeline.addLight(.{ .position = .{ .x = 0.5, .y = 0.5 }, .radius = 2, .color = .rgb(0, 128, 255) });
    var camera = Camera2D{ .position = .{ .x = 0, .y = 0 } };
    var direct = try @import("canvas.zig").Canvas.init(std.testing.allocator, 4, 2);
    defer direct.deinit();
    direct.clear(Color.black);
    _ = pipeline.render(.init(&direct, &camera));

    var commands = CommandBuffer.init(std.testing.allocator);
    defer commands.deinit();
    const metrics = try pipeline.append(&commands, &camera, .{ .x = 4, .y = 2 });
    try std.testing.expectEqual(RenderPath.gpu_primitives, metrics.path);
    try std.testing.expectEqual(RenderPath.gpu_primitives, Pipeline.preferredPath(true));
    try std.testing.expectEqual(RenderPath.headless_fallback, Pipeline.preferredPath(false));
    var command_canvas = try @import("canvas.zig").Canvas.init(std.testing.allocator, 4, 2);
    defer command_canvas.deinit();
    command_canvas.clear(Color.black);
    var renderer = HeadlessRenderer.init(std.testing.allocator, &command_canvas);
    defer renderer.deinit();
    try renderer.submit(commands.commands.items);
    try std.testing.expectEqualSlices(Color, direct.pixels, command_canvas.pixels);
}
