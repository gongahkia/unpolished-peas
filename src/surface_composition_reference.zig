//! Independent scalar oracle for the pre-optimization surface contract.
//! Do not call production sampling, tint or blend helpers here. In particular,
//! each horizontal interpolation rounds to u8 before vertical interpolation.
const std = @import("std");
const up = @import("unpolished-peas");
const Color = up.core.Color;
const Canvas = up.graphics.Canvas;
const Surface = up.graphics.RenderSurface;
const Options = up.graphics.SurfaceDrawOptions;

pub fn draw(destination: *Canvas, source: *const Surface, options: Options) !void {
    if (options.width == 0 or options.height == 0 or options.width > std.math.maxInt(i32) or options.height > std.math.maxInt(i32)) return error.InvalidSurfaceDrawSize;
    if (destination == &source.target) return error.SurfaceSelfSampling;
    if (destination.trace) |trace| trace.recordSurface(source.width(), source.height(), source.target.pixels, options.x, options.y, options.width, options.height, options.tint, switch (options.filter) {
        .nearest => .nearest,
        .linear => .linear,
    });
    for (0..destination.height) |y| for (0..destination.width) |x| {
        const rx = @as(i64, @intCast(x)) - options.x;
        const ry = @as(i64, @intCast(y)) - options.y;
        if (rx < 0 or ry < 0 or rx >= options.width or ry >= options.height) continue;
        if (destination.clip) |clip| {
            if (@as(i64, @intCast(x)) < clip.x or @as(i64, @intCast(y)) < clip.y or
                @as(i64, @intCast(x)) >= @as(i64, clip.x) + clip.w or @as(i64, @intCast(y)) >= @as(i64, clip.y) + clip.h) continue;
        }
        const sample = switch (options.filter) {
            .nearest => source.target.pixels[@as(usize, @intCast(@as(u64, @intCast(ry)) * source.height() / options.height)) * source.width() + @as(usize, @intCast(@as(u64, @intCast(rx)) * source.width() / options.width))],
            .linear => linear(source, @intCast(rx), @intCast(ry), options.width, options.height),
        };
        const tinted = Color.rgba(
            @intCast(@as(u16, sample.r) * options.tint.r / 255),
            @intCast(@as(u16, sample.g) * options.tint.g / 255),
            @intCast(@as(u16, sample.b) * options.tint.b / 255),
            @intCast(@as(u16, sample.a) * options.tint.a / 255),
        );
        const destination_pixel = &destination.pixels[y * destination.width + x];
        destination_pixel.* = blend(tinted, destination_pixel.*, destination.blend);
    };
}

fn linear(source: *const Surface, x: u32, y: u32, width: u32, height: u32) Color {
    const sx = ((@as(f32, @floatFromInt(x)) + 0.5) * @as(f32, @floatFromInt(source.width())) / @as(f32, @floatFromInt(width))) - 0.5;
    const sy = ((@as(f32, @floatFromInt(y)) + 0.5) * @as(f32, @floatFromInt(source.height())) / @as(f32, @floatFromInt(height))) - 0.5;
    const left = std.math.clamp(@as(i32, @intFromFloat(@floor(sx))), 0, @as(i32, @intCast(source.width() - 1)));
    const top = std.math.clamp(@as(i32, @intFromFloat(@floor(sy))), 0, @as(i32, @intCast(source.height() - 1)));
    const right = @min(left + 1, @as(i32, @intCast(source.width() - 1)));
    const bottom = @min(top + 1, @as(i32, @intCast(source.height() - 1)));
    const fx = std.math.clamp(sx - @as(f32, @floatFromInt(left)), 0, 1);
    const fy = std.math.clamp(sy - @as(f32, @floatFromInt(top)), 0, 1);
    const a = mix(pixel(source, left, top), pixel(source, right, top), fx);
    const b = mix(pixel(source, left, bottom), pixel(source, right, bottom), fx);
    return mix(a, b, fy);
}

fn pixel(source: *const Surface, x: i32, y: i32) Color {
    return source.target.pixels[@as(usize, @intCast(y)) * source.width() + @as(usize, @intCast(x))];
}
fn channel(a: u8, b: u8, t: f32) u8 {
    const value = @as(f32, @floatFromInt(a)) + (@as(f32, @floatFromInt(b)) - @as(f32, @floatFromInt(a))) * t;
    return @intFromFloat(@round(std.math.clamp(value, 0, 255)));
}
fn mix(a: Color, b: Color, t: f32) Color {
    return .{ .r = channel(a.r, b.r, t), .g = channel(a.g, b.g, t), .b = channel(a.b, b.b, t), .a = channel(a.a, b.a, t) };
}

fn blend(src: Color, dst: Color, mode: up.graphics.BlendMode) Color {
    if (mode == .alpha) {
        if (src.a == 0) return dst;
        if (src.a == 255) return src;
        const a: u16 = src.a;
        const inverse = 255 - a;
        return .{ .r = @intCast((@as(u16, src.r) * a + @as(u16, dst.r) * inverse) / 255), .g = @intCast((@as(u16, src.g) * a + @as(u16, dst.g) * inverse) / 255), .b = @intCast((@as(u16, src.b) * a + @as(u16, dst.b) * inverse) / 255), .a = 255 };
    }
    const a: u16 = src.a;
    return .{ .r = @intCast(@min(255, @as(u16, dst.r) + @as(u16, src.r) * a / 255)), .g = @intCast(@min(255, @as(u16, dst.g) + @as(u16, src.g) * a / 255)), .b = @intCast(@min(255, @as(u16, dst.b) + @as(u16, src.b) * a / 255)), .a = 255 };
}
