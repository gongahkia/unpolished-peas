const std = @import("std");

pub const Vec2 = struct {
    x: f32 = 0,
    y: f32 = 0,

    pub const zero: Vec2 = .{};

    pub fn init(x: f32, y: f32) Vec2 {
        return .{ .x = x, .y = y };
    }

    pub fn add(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }

    pub fn sub(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }

    pub fn scale(v: Vec2, amount: f32) Vec2 {
        return .{ .x = v.x * amount, .y = v.y * amount };
    }

    pub fn dot(a: Vec2, b: Vec2) f32 {
        return a.x * b.x + a.y * b.y;
    }

    pub fn lenSq(v: Vec2) f32 {
        return dot(v, v);
    }

    pub fn len(v: Vec2) f32 {
        return std.math.sqrt(v.lenSq());
    }

    pub fn normalized(v: Vec2) Vec2 {
        const l = v.len();
        if (l == 0) return .{};
        return v.scale(1 / l);
    }
};

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn init(x: f32, y: f32, w: f32, h: f32) Rect {
        return .{ .x = x, .y = y, .w = w, .h = h };
    }

    pub fn contains(self: Rect, p: Vec2) bool {
        return p.x >= self.x and p.y >= self.y and p.x < self.x + self.w and p.y < self.y + self.h;
    }

    pub fn intersects(a: Rect, b: Rect) bool {
        return a.x < b.x + b.w and a.x + a.w > b.x and a.y < b.y + b.h and a.y + a.h > b.y;
    }
};

test "vec2 basics" {
    const a = Vec2.init(3, 4);
    try std.testing.expectEqual(@as(f32, 25), a.lenSq());
    try std.testing.expectApproxEqAbs(@as(f32, 5), a.len(), 0.001);
    try std.testing.expectEqual(Vec2.init(4, 6), a.add(Vec2.init(1, 2)));
}

test "rect hit tests" {
    const a = Rect.init(0, 0, 10, 10);
    const b = Rect.init(9, 9, 2, 2);
    const c = Rect.init(11, 11, 1, 1);
    try std.testing.expect(a.contains(Vec2.init(5, 5)));
    try std.testing.expect(a.intersects(b));
    try std.testing.expect(!a.intersects(c));
}
