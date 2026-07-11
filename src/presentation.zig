const std = @import("std");
const Vec2 = @import("math.zig").Vec2;

pub const PresentationMode = enum {
    stretch,
    fit,
    integer_fit,
};

pub const PresentationRect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

pub const Presentation = struct {
    canvas_size: Vec2,
    framebuffer_size: Vec2,
    mode: PresentationMode = .integer_fit,

    pub fn init(canvas_size: Vec2, framebuffer_size: Vec2, mode: PresentationMode) Presentation {
        return .{ .canvas_size = canvas_size, .framebuffer_size = framebuffer_size, .mode = mode };
    }

    pub fn destination(self: Presentation) PresentationRect {
        if (self.canvas_size.x <= 0 or self.canvas_size.y <= 0 or self.framebuffer_size.x <= 0 or self.framebuffer_size.y <= 0) return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        const scale = switch (self.mode) {
            .stretch => return .{ .x = 0, .y = 0, .w = self.framebuffer_size.x, .h = self.framebuffer_size.y },
            .fit => @min(self.framebuffer_size.x / self.canvas_size.x, self.framebuffer_size.y / self.canvas_size.y),
            .integer_fit => blk: {
                const fit = @min(self.framebuffer_size.x / self.canvas_size.x, self.framebuffer_size.y / self.canvas_size.y);
                break :blk if (fit >= 1) @floor(fit) else fit;
            },
        };
        const w = self.canvas_size.x * scale;
        const h = self.canvas_size.y * scale;
        return .{ .x = (self.framebuffer_size.x - w) / 2, .y = (self.framebuffer_size.y - h) / 2, .w = w, .h = h };
    }

    pub fn framebufferToCanvas(self: Presentation, point: Vec2) ?Vec2 {
        const dest = self.destination();
        if (dest.w <= 0 or dest.h <= 0 or point.x < dest.x or point.y < dest.y or point.x >= dest.x + dest.w or point.y >= dest.y + dest.h) return null;
        return .{
            .x = (point.x - dest.x) * self.canvas_size.x / dest.w,
            .y = (point.y - dest.y) * self.canvas_size.y / dest.h,
        };
    }

    pub fn canvasToFramebuffer(self: Presentation, point: Vec2) ?Vec2 {
        const dest = self.destination();
        if (dest.w <= 0 or dest.h <= 0) return null;
        return .{
            .x = dest.x + point.x * dest.w / self.canvas_size.x,
            .y = dest.y + point.y * dest.h / self.canvas_size.y,
        };
    }
};

test "integer presentation centers logical canvas" {
    const presentation = Presentation.init(.{ .x = 320, .y = 180 }, .{ .x = 1000, .y = 800 }, .integer_fit);
    const dest = presentation.destination();
    try std.testing.expectEqual(PresentationRect{ .x = 20, .y = 130, .w = 960, .h = 540 }, dest);
    try std.testing.expectEqual(Vec2.init(160, 90), presentation.framebufferToCanvas(.{ .x = 500, .y = 400 }).?);
    try std.testing.expect(presentation.framebufferToCanvas(.{ .x = 10, .y = 10 }) == null);
}

test "fit presentation round trips coordinates" {
    const presentation = Presentation.init(.{ .x = 320, .y = 180 }, .{ .x = 1000, .y = 800 }, .fit);
    const point = Vec2.init(71, 13);
    const round_trip = presentation.framebufferToCanvas(presentation.canvasToFramebuffer(point).?).?;
    try std.testing.expectApproxEqAbs(point.x, round_trip.x, 0.001);
    try std.testing.expectApproxEqAbs(point.y, round_trip.y, 0.001);
}
