const std = @import("std");

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

    pub fn apply(self: PixelEffect, color: anytype) @TypeOf(color) {
        var result = color;
        switch (self.kind) {
            .invert => {
                result.r = mix(color.r, 255 - color.r, self.amount);
                result.g = mix(color.g, 255 - color.g, self.amount);
                result.b = mix(color.b, 255 - color.b, self.amount);
            },
            .passthrough => {},
        }
        return result;
    }
};

pub const Parameters = struct { amount: f32 = 1 };

pub const Chain = struct {
    effects: [8]PixelEffect = undefined,
    len: u8 = 0,

    pub fn append(self: *Chain, effect: PixelEffect) !void {
        if (self.len == self.effects.len) return error.TooManyPostProcessPasses;
        self.effects[self.len] = effect;
        self.len += 1;
    }

    pub fn replace(self: *Chain, effect: PixelEffect) void {
        self.effects[0] = effect;
        self.len = 1;
    }

    pub fn clear(self: *Chain) void {
        self.len = 0;
    }

    pub fn items(self: *const Chain) []const PixelEffect {
        return self.effects[0..self.len];
    }

    pub fn apply(self: Chain, color: anytype) @TypeOf(color) {
        var result = color;
        for (self.effects[0..self.len]) |effect| result = effect.apply(result);
        return result;
    }
};

pub fn applyPixelEffect(surface: anytype, effect: PixelEffect) void {
    for (surface.pixels) |*pixel| pixel.* = effect.apply(pixel.*);
}

fn mix(a: u8, b: u8, amount: f32) u8 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(a)) + (@as(f32, @floatFromInt(b)) - @as(f32, @floatFromInt(a))) * amount));
}

const TestColor = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

test "shader compilation validates reflection and generic color fallback" {
    const program = try Program.compile("effect=invert\nuniform amount:f32\n");
    const effect = try program.instantiate(.{ .amount = 0.5 });
    try std.testing.expectEqual(TestColor{ .r = 128, .g = 128, .b = 128, .a = 64 }, effect.apply(.{ .r = 0, .g = 0, .b = 0, .a = 64 }));
    const passthrough = try Program.compile("effect=passthrough");
    try std.testing.expectEqual(TestColor{ .r = 1, .g = 2, .b = 3, .a = 4 }, (try passthrough.instantiate(.{})).apply(.{ .r = 1, .g = 2, .b = 3, .a = 4 }));
    try std.testing.expectError(error.InvalidShaderReflection, Program.compile("effect=invert"));
    try std.testing.expectError(error.InvalidShaderSource, Program.compile("effect=blur"));
    try std.testing.expectError(error.InvalidShaderParameter, program.instantiate(.{ .amount = 2 }));
}

test "post-process chains preserve declared pass order" {
    var chain = Chain{};
    try chain.append(try PixelEffect.parse("invert", .{ .amount = 1 }));
    try chain.append(try PixelEffect.parse("invert", .{ .amount = 1 }));
    try std.testing.expectEqual(TestColor{ .r = 12, .g = 34, .b = 56, .a = 255 }, chain.apply(.{ .r = 12, .g = 34, .b = 56, .a = 255 }));
    chain.clear();
    try std.testing.expectEqual(@as(usize, 0), chain.items().len);
}

test "pixel-effect helper transforms a structural surface" {
    var pixels = [_]TestColor{.{ .r = 10, .g = 20, .b = 30, .a = 255 }};
    var surface = struct { pixels: []TestColor }{ .pixels = &pixels };
    applyPixelEffect(&surface, try PixelEffect.parse("invert", .{}));
    try std.testing.expectEqual(TestColor{ .r = 245, .g = 235, .b = 225, .a = 255 }, pixels[0]);
}
