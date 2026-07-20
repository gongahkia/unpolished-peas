const std = @import("std");
const Vec2 = @import("math.zig").Vec2;
const Rect = @import("math.zig").Rect;

pub const Sampling = enum { nearest, bilinear };
pub const PixelSnap = enum { off, nearest };

pub const CameraViewport = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32,
    h: f32,

    pub fn full(size: Vec2) CameraViewport {
        return .{ .w = size.x, .h = size.y };
    }

    pub fn rect(self: CameraViewport) Rect {
        return .init(self.x, self.y, self.w, self.h);
    }
};

pub const Camera2D = struct {
    position: Vec2 = .{},
    zoom: f32 = 1,
    rotation: f32 = 0,
    viewport: ?CameraViewport = null,
    sampling: Sampling = .nearest,
    pixel_snap: PixelSnap = .nearest,

    pub fn setZoom(self: *Camera2D, value: f32) void {
        self.zoom = @max(0.05, @min(64, value));
    }

    pub fn worldToCanvas(self: Camera2D, point: Vec2, canvas_size: Vec2) Vec2 {
        const value = self.worldToCanvasUnsnapped(point, canvas_size);
        return switch (self.pixel_snap) {
            .off => value,
            .nearest => .{ .x = @round(value.x), .y = @round(value.y) },
        };
    }

    pub fn canvasToWorld(self: Camera2D, point: Vec2, canvas_size: Vec2) Vec2 {
        const viewport = self.canvasViewport(canvas_size);
        const local = point.sub(.{ .x = viewport.x + viewport.w / 2, .y = viewport.y + viewport.h / 2 }).scale(1 / self.zoom);
        return self.position.add(rotate(local, self.rotation));
    }

    pub fn canvasViewport(self: Camera2D, canvas_size: Vec2) CameraViewport {
        return self.viewport orelse CameraViewport.full(canvas_size);
    }

    pub fn worldBounds(self: Camera2D, canvas_size: Vec2) Rect {
        const viewport = self.canvasViewport(canvas_size);
        const points = [_]Vec2{
            self.canvasToWorld(.{ .x = viewport.x, .y = viewport.y }, canvas_size),
            self.canvasToWorld(.{ .x = viewport.x + viewport.w, .y = viewport.y }, canvas_size),
            self.canvasToWorld(.{ .x = viewport.x, .y = viewport.y + viewport.h }, canvas_size),
            self.canvasToWorld(.{ .x = viewport.x + viewport.w, .y = viewport.y + viewport.h }, canvas_size),
        };
        var min = points[0];
        var max = points[0];
        for (points[1..]) |point| {
            min.x = @min(min.x, point.x);
            min.y = @min(min.y, point.y);
            max.x = @max(max.x, point.x);
            max.y = @max(max.y, point.y);
        }
        return .init(min.x, min.y, max.x - min.x, max.y - min.y);
    }

    pub fn isVisibleRect(self: Camera2D, rect: Rect, canvas_size: Vec2) bool {
        return self.worldBounds(canvas_size).intersects(rect);
    }

    fn worldToCanvasUnsnapped(self: Camera2D, point: Vec2, canvas_size: Vec2) Vec2 {
        const viewport = self.canvasViewport(canvas_size);
        const local = rotate(point.sub(self.position), -self.rotation).scale(self.zoom);
        return .{ .x = viewport.x + viewport.w / 2 + local.x, .y = viewport.y + viewport.h / 2 + local.y };
    }
};

fn rotate(point: Vec2, radians: f32) Vec2 {
    const cosine = @cos(radians);
    const sine = @sin(radians);
    return .{ .x = point.x * cosine - point.y * sine, .y = point.x * sine + point.y * cosine };
}

test "camera transforms points through one position zoom rotation helper" {
    var camera = Camera2D{ .position = .{ .x = 40, .y = 24 }, .zoom = 2, .rotation = 0.4, .pixel_snap = .off };
    const canvas_size = Vec2.init(160, 90);
    const point = Vec2.init(47, 31);
    const got = camera.canvasToWorld(camera.worldToCanvas(point, canvas_size), canvas_size);
    try std.testing.expectApproxEqAbs(point.x, got.x, 0.001);
    try std.testing.expectApproxEqAbs(point.y, got.y, 0.001);
    camera.setZoom(0);
    try std.testing.expectEqual(@as(f32, 0.05), camera.zoom);
}
