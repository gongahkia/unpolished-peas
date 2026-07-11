const std = @import("std");
const Vec2 = @import("math.zig").Vec2;
const Rect = @import("math.zig").Rect;

pub const Circle = struct { center: Vec2, radius: f32 };
pub const Segment = struct { a: Vec2, b: Vec2 };
pub const Polygon = struct { points: []const Vec2 };
pub const Contact = struct { point: Vec2, normal: Vec2, depth: f32 };
pub const RayHit = struct { point: Vec2, normal: Vec2, fraction: f32 };

pub fn rectOverlap(a: Rect, b: Rect) bool {
    return a.x <= b.x + b.w and a.x + a.w >= b.x and a.y <= b.y + b.h and a.y + a.h >= b.y;
}
pub fn circleOverlap(a: Circle, b: Circle) bool {
    const radius = a.radius + b.radius;
    return a.center.sub(b.center).lenSq() <= radius * radius;
}
pub fn rectCircleOverlap(rect: Rect, circle: Circle) bool {
    const x = std.math.clamp(circle.center.x, rect.x, rect.x + rect.w);
    const y = std.math.clamp(circle.center.y, rect.y, rect.y + rect.h);
    return circle.center.sub(.{ .x = x, .y = y }).lenSq() <= circle.radius * circle.radius;
}
pub fn segmentOverlap(a: Segment, b: Segment) bool {
    const ab = a.b.sub(a.a);
    const cd = b.b.sub(b.a);
    const denom = cross(ab, cd);
    if (denom == 0) return cross(b.a.sub(a.a), ab) == 0 and rangesOverlap(a.a.x, a.b.x, b.a.x, b.b.x) and rangesOverlap(a.a.y, a.b.y, b.a.y, b.b.y);
    const t = cross(b.a.sub(a.a), cd) / denom;
    const u = cross(b.a.sub(a.a), ab) / denom;
    return t >= 0 and t <= 1 and u >= 0 and u <= 1;
}
pub fn pointInPolygon(point: Vec2, polygon: Polygon) bool {
    if (polygon.points.len < 3) return false;
    var inside = false;
    var previous = polygon.points[polygon.points.len - 1];
    for (polygon.points) |current| {
        if ((current.y > point.y) != (previous.y > point.y) and point.x <= (previous.x - current.x) * (point.y - current.y) / (previous.y - current.y) + current.x) inside = !inside;
        previous = current;
    }
    return inside;
}
pub fn raycastRect(origin: Vec2, delta: Vec2, rect: Rect) ?RayHit {
    var near_x = (rect.x - origin.x) / delta.x;
    var far_x = (rect.x + rect.w - origin.x) / delta.x;
    var near_y = (rect.y - origin.y) / delta.y;
    var far_y = (rect.y + rect.h - origin.y) / delta.y;
    if (delta.x == 0) {
        near_x = -std.math.inf(f32);
        far_x = std.math.inf(f32);
    }
    if (delta.y == 0) {
        near_y = -std.math.inf(f32);
        far_y = std.math.inf(f32);
    }
    if (near_x > far_x) std.mem.swap(f32, &near_x, &far_x);
    if (near_y > far_y) std.mem.swap(f32, &near_y, &far_y);
    const enter = @max(near_x, near_y);
    const exit = @min(far_x, far_y);
    if (enter > exit or exit < 0 or enter > 1) return null;
    const fraction = @max(enter, 0);
    const normal = if (near_x > near_y) Vec2.init(if (delta.x > 0) -1 else 1, 0) else Vec2.init(0, if (delta.y > 0) -1 else 1);
    return .{ .point = origin.add(delta.scale(fraction)), .normal = normal, .fraction = fraction };
}
pub fn sweepRect(moving: Rect, delta: Vec2, target: Rect) ?RayHit {
    const expanded = Rect.init(target.x - moving.w, target.y - moving.h, target.w + moving.w, target.h + moving.h);
    return raycastRect(.{ .x = moving.x, .y = moving.y }, delta, expanded);
}
fn cross(a: Vec2, b: Vec2) f32 {
    return a.x * b.y - a.y * b.x;
}
fn rangesOverlap(a0: f32, a1: f32, b0: f32, b1: f32) bool {
    return @max(@min(a0, a1), @min(b0, b1)) <= @min(@max(a0, a1), @max(b0, b1));
}

test "collision covers tangency containment degeneracy and sweep" {
    try std.testing.expect(rectOverlap(Rect.init(0, 0, 1, 1), Rect.init(1, 0, 1, 1)));
    try std.testing.expect(circleOverlap(.{ .center = .{}, .radius = 1 }, .{ .center = .{ .x = 2, .y = 0 }, .radius = 1 }));
    try std.testing.expect(rectCircleOverlap(Rect.init(0, 0, 4, 4), .{ .center = .{ .x = 2, .y = 2 }, .radius = 1 }));
    try std.testing.expect(segmentOverlap(.{ .a = .{ .x = 0, .y = 0 }, .b = .{ .x = 1, .y = 0 } }, .{ .a = .{ .x = 1, .y = 0 }, .b = .{ .x = 2, .y = 0 } }));
    try std.testing.expect(pointInPolygon(.{ .x = 1, .y = 1 }, .{ .points = &.{ .{ .x = 0, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 0, .y = 2 } } }));
    try std.testing.expect((raycastRect(.{ .x = -1, .y = 0.5 }, .{ .x = 2, .y = 0 }, Rect.init(0, 0, 1, 1))).?.fraction == 0.5);
}
