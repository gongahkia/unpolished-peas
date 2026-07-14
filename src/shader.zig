const std = @import("std");
const Color = @import("color.zig").Color;

pub const Kind = enum { invert, passthrough };
pub const Reflection = struct { requires_amount: bool = false };

pub const Program = struct {
    kind: Kind,
    reflection: Reflection,

    pub fn compile(source: []const u8) !Program {
        var effect: ?Kind = null;
        var amount_declared = false;
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or std.mem.startsWith(u8, line, "#")) continue;
            if (std.mem.startsWith(u8, line, "effect=")) {
                if (effect != null) return error.InvalidShaderSource;
                effect = std.meta.stringToEnum(Kind, line["effect=".len..]) orelse return error.InvalidShaderSource;
                continue;
            }
            if (std.mem.eql(u8, line, "uniform amount:f32")) {
                if (amount_declared) return error.InvalidShaderReflection;
                amount_declared = true;
                continue;
            }
            return error.InvalidShaderSource;
        }
        const kind = effect orelse return error.InvalidShaderSource;
        const requires_amount = kind == .invert;
        if (requires_amount != amount_declared) return error.InvalidShaderReflection;
        return .{ .kind = kind, .reflection = .{ .requires_amount = requires_amount } };
    }

    pub fn instantiate(self: Program, params: Parameters) !PixelEffect {
        if (self.reflection.requires_amount and (!std.math.isFinite(params.amount) or params.amount < 0 or params.amount > 1)) return error.InvalidShaderParameter;
        return .{ .kind = self.kind, .amount = params.amount };
    }
};

pub const PixelEffect = struct {
    kind: Kind,
    amount: f32 = 1,

    pub fn parse(source: []const u8, params: Parameters) !PixelEffect {
        const kind = std.meta.stringToEnum(Kind, source) orelse return error.InvalidShaderSource;
        return (Program{ .kind = kind, .reflection = .{ .requires_amount = kind == .invert } }).instantiate(params);
    }

    pub fn apply(self: PixelEffect, color: Color) Color {
        return switch (self.kind) {
            .invert => .{
                .r = mix(color.r, 255 - color.r, self.amount),
                .g = mix(color.g, 255 - color.g, self.amount),
                .b = mix(color.b, 255 - color.b, self.amount),
                .a = color.a,
            },
            .passthrough => color,
        };
    }
};

pub const Parameters = struct { amount: f32 = 1 };

fn mix(a: u8, b: u8, amount: f32) u8 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(a)) + (@as(f32, @floatFromInt(b)) - @as(f32, @floatFromInt(a))) * amount));
}

test "shader compilation validates reflection and headless fallback" {
    const program = try Program.compile("effect=invert\nuniform amount:f32\n");
    const effect = try program.instantiate(.{ .amount = 0.5 });
    try std.testing.expectEqual(Color.rgba(128, 128, 128, 64), effect.apply(Color.rgba(0, 0, 0, 64)));
    const passthrough = try Program.compile("effect=passthrough");
    try std.testing.expectEqual(Color.white, (try passthrough.instantiate(.{})).apply(Color.white));
    try std.testing.expectError(error.InvalidShaderReflection, Program.compile("effect=invert"));
    try std.testing.expectError(error.InvalidShaderSource, Program.compile("effect=blur"));
    try std.testing.expectError(error.InvalidShaderParameter, program.instantiate(.{ .amount = 2 }));
}
