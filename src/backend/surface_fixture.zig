//! Shared native/browser rendered fixtures for the public surface compositor.
const std = @import("std");
const up = @import("unpolished-peas");
const Comp = up.graphics.SurfaceCompositor;
const Color = up.core.Color;
pub const case_count = 12;
pub const width = 48;
pub const height = 32;
pub const Fixture = struct {
    allocator: std.mem.Allocator,
    scene: ?Comp = null,
    first: ?up.graphics.RenderSurface = null,
    second: ?up.graphics.RenderSurface = null,
    first_layer: Comp.Layer = undefined,
    second_layer: Comp.Layer = undefined,
    font: ?up.assets.Font = null,
    text: ?up.assets.Font.TextLayout = null,
    case_index: u32 = 0,
    frames: u32 = 0,
    pub fn init(allocator: std.mem.Allocator, font_bytes: []const u8) !*Fixture {
        const self = try allocator.create(Fixture);
        self.* = .{ .allocator = allocator };
        errdefer self.deinit();
        self.scene = try Comp.init(allocator, .{ .layers = 3, .draws = 8, .max_source_bytes = 4096 });
        self.first = try up.graphics.RenderSurface.init(allocator, 7, 5);
        self.second = try up.graphics.RenderSurface.init(allocator, 9, 7);
        self.first_layer = try self.scene.?.retain(&self.first.?);
        self.second_layer = try self.scene.?.retain(&self.second.?);
        self.font = try up.assets.Font.decodeTrueType(allocator, font_bytes, .{ .pixel_height = 8 });
        self.text = try self.font.?.layoutText(allocator, "Wi iii\nZoë", .{ .max_width = 36, .alignment = .center });
        return self;
    }
    pub fn deinit(self: *Fixture) void {
        if (self.scene) |*value| value.deinit();
        if (self.text) |*value| value.deinit();
        if (self.font) |*value| value.deinit();
        if (self.first) |*value| value.deinit();
        if (self.second) |*value| value.deinit();
        self.allocator.destroy(self);
    }
    pub fn draw(self: *Fixture, canvas: *up.graphics.Canvas, index: u32) !void {
        if (index >= case_count) return error.InvalidCompositionFixture;
        self.case_index = index;
        self.frames += 1;
        if (index == 10) {
            canvas.clear(Color.rgb(17, 79, 113));
            return;
        }
        const previous = canvas.preserve_alpha;
        defer canvas.preserve_alpha = previous;
        canvas.preserve_alpha = true;
        canvas.clear(Color.transparent);
        if (index != 0) {
            self.text.?.draw(canvas, 3, 5, Color.rgba(255, 230, 180, 180));
            canvas.fillRect(1, 1, 5, 3, Color.rgba(40, 150, 230, 190));
        } else canvas.fillRect(1, 1, 5, 3, Color.rgb(40, 150, 230));
        for (self.first.?.target.pixels, 0..) |*pixel, i| pixel.* = Color.rgba(@intCast(i * 31 % 256), @intCast(i * 17 % 256), @intCast(i * 7 % 256), if (index == 0) 255 else @intCast(40 + i * 13 % 216));
        for (self.second.?.target.pixels, 0..) |*pixel, i| pixel.* = Color.rgba(@intCast(20 + i % 200), @intCast(50 + i % 180), @intCast(230 - i % 100), if (index == 0) 255 else if (i % 5 == 0) 0 else 120);
        const scene = &self.scene.?;
        try scene.beginFrame(Color.rgb(12, 24, 36));
        if (index == 9) {
            const stale = self.second_layer;
            try scene.release(stale);
            self.second_layer = try scene.retain(&self.second.?);
            if (scene.getSurface(stale)) |_| return error.StaleFixtureHandleAccepted else |err| if (err != error.StaleCompositionLayer) return err;
        }
        if (index == 4) try scene.drawCanvas();
        try scene.drawLayer(self.first_layer, .{ .surface = .{
            .x = if (index == 11) -3 else 0,
            .y = if (index == 11) -2 else 0,
            .width = if (index == 11) canvas.width + 5 else canvas.width,
            .height = if (index == 11) canvas.height + 3 else canvas.height,
            .filter = if (index == 1 or index == 11) .linear else .nearest,
            .tint = if (index == 2) Color.rgba(150, 220, 70, 130) else Color.white,
        } });
        if (index == 5) try scene.drawCanvas();
        try scene.drawLayer(self.second_layer, .{ .surface = .{
            .x = 9,
            .y = 7,
            .width = 27,
            .height = 21,
            .filter = if (index == 1) .linear else .nearest,
            .tint = if (index == 2) Color.rgba(240, 150, 200, 170) else Color.white,
        }, .clip = if (index == 3) .{ .x = -2, .y = 4, .w = 21, .h = 17 } else if (index == 7) .{ .x = 200, .y = 200, .w = 3, .h = 3 } else null });
        if (index == 6) try scene.drawLayer(self.second_layer, .{ .surface = .{ .x = 1, .y = 2, .width = 17, .height = 13, .filter = .linear, .tint = Color.rgba(180, 240, 90, 90) } });
        if (index != 4 and index != 5) try scene.drawCanvas();
        // A direct write after queueing must be picked up by submission.
        if (index == 8) @memset(self.first.?.target.pixels, Color.rgb(231, 35, 74));
    }
    pub fn drawCpu(self: *Fixture, target: *up.graphics.Canvas, canvas: *const up.graphics.Canvas) !void {
        if (self.case_index == 10) @memcpy(target.pixels, canvas.pixels) else try self.scene.?.drawCpu(target, canvas);
    }
};
