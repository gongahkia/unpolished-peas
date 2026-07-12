const std = @import("std");
const Color = @import("color.zig").Color;

pub const PixelEffect = struct {
    amount: f32,

    pub fn parse(source: []const u8, params: Parameters) !PixelEffect {
        if (!std.mem.eql(u8, source, "invert")) return error.InvalidShaderSource;
        if (!std.math.isFinite(params.amount) or params.amount < 0 or params.amount > 1) return error.InvalidShaderParameter;
        return .{ .amount = params.amount };
    }

    pub fn apply(self: PixelEffect, color: Color) Color {
        return .{
            .r = mix(color.r, 255 - color.r, self.amount),
            .g = mix(color.g, 255 - color.g, self.amount),
            .b = mix(color.b, 255 - color.b, self.amount),
            .a = color.a,
        };
    }
};

pub const Parameters = struct {
    amount: f32 = 1,
};

fn mix(a: u8, b: u8, amount: f32) u8 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(a)) + (@as(f32, @floatFromInt(b)) - @as(f32, @floatFromInt(a))) * amount));
}

test "strict invert effect validates source and bounded parameters" {
    const effect = try PixelEffect.parse("invert", .{ .amount = 0.5 });
    try std.testing.expectEqual(Color.rgba(128, 128, 128, 64), effect.apply(Color.rgba(0, 0, 0, 64)));
    try std.testing.expectError(error.InvalidShaderSource, PixelEffect.parse("blur", .{}));
    try std.testing.expectError(error.InvalidShaderParameter, PixelEffect.parse("invert", .{ .amount = 2 }));
}
