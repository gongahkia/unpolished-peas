//! Internal, fixed CPU-composition workloads. Setup is outside timed regions.
const up = @import("unpolished-peas");
pub const Pattern = enum { solid, opaque_pattern, alpha_pattern };
pub const Case = struct {
    name: []const u8,
    source_width: u32 = 320,
    source_height: u32 = 180,
    width: u32 = 1280,
    height: u32 = 720,
    filter: up.graphics.SurfaceFilter = .linear,
    pattern: Pattern = .solid,
    tint: up.core.Color = up.core.Color.white,
    blend: up.graphics.BlendMode = .alpha,
    x: i32 = 0,
    y: i32 = 0,
    clip: ?up.graphics.ClipRect = null,

    pub fn options(self: Case) up.graphics.SurfaceDrawOptions {
        return .{ .x = self.x, .y = self.y, .width = self.width, .height = self.height, .filter = self.filter, .tint = self.tint };
    }
    pub fn visiblePixels(self: Case) u64 {
        var left = @max(@as(i64, 0), self.x);
        var top = @max(@as(i64, 0), self.y);
        var right = @min(@as(i64, self.width), @as(i64, self.x) + self.width);
        var bottom = @min(@as(i64, self.height), @as(i64, self.y) + self.height);
        if (self.clip) |clip| {
            left = @max(left, clip.x);
            top = @max(top, clip.y);
            right = @min(right, @as(i64, clip.x) + clip.w);
            bottom = @min(bottom, @as(i64, clip.y) + clip.h);
        }
        return if (left >= right or top >= bottom) 0 else @intCast((right - left) * (bottom - top));
    }
};

pub const cases = [_]Case{
    .{ .name = "surface_1to1_nearest", .width = 320, .height = 180, .filter = .nearest },
    .{ .name = "surface_160x90_to_1280x720_nearest", .source_width = 160, .source_height = 90, .filter = .nearest },
    .{ .name = "surface_320x180_to_1280x720_nearest", .filter = .nearest },
    .{ .name = "surface_160x90_to_1280x720_linear", .source_width = 160, .source_height = 90 },
    .{ .name = "surface_320x180_to_1280x720_linear" },
    .{ .name = "pattern_linear_320x180_to_1280x720", .pattern = .opaque_pattern },
    .{ .name = "alpha_linear_320x180_to_1280x720", .pattern = .alpha_pattern },
    .{ .name = "tinted_additive_linear_clipped", .source_width = 317, .source_height = 179, .width = 1279, .height = 719, .pattern = .alpha_pattern, .tint = up.core.Color.rgba(201, 109, 237, 177), .blend = .additive, .x = -13, .y = 7, .clip = .{ .x = 11, .y = 17, .w = 1201, .h = 683 } },
    .{ .name = "downscale_linear_640x360_to_317x179", .source_width = 640, .source_height = 360, .width = 317, .height = 179, .pattern = .opaque_pattern },
    .{ .name = "odd_alpha_linear_37x23_to_1001x563", .source_width = 37, .source_height = 23, .width = 1001, .height = 563, .pattern = .alpha_pattern, .tint = up.core.Color.rgba(99, 187, 239, 213) },
    .{ .name = "thin_alpha_linear_1x180_to_1280x720", .source_width = 1, .pattern = .alpha_pattern },
    .{ .name = "pattern_linear_1to1", .width = 320, .height = 180, .pattern = .opaque_pattern },
};

pub fn populate(surface: *up.graphics.RenderSurface, pattern: Pattern) void {
    for (surface.canvas().pixels, 0..) |*pixel, i| {
        const x = i % surface.width();
        const y = i / surface.width();
        pixel.* = if (pattern == .solid) up.core.Color.rgb(40, 80, 120) else up.core.Color.rgba(
            @intCast((x * 13 + y * 37) % 256),
            @intCast((x * 29 + y * 11) % 256),
            @intCast((x * 47 + y * 23) % 256),
            if (pattern == .opaque_pattern) 255 else ([_]u8{ 0, 1, 64, 128, 254, 255 })[(x + y * 3) % 6],
        );
    }
}
