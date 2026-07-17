const std = @import("std");
const api = @import("api.zig");
const app = @import("app.zig");
const color = @import("color.zig");
const math = @import("math.zig");
const expected_declarations = [_][]const u8{ "App", "StepClock", "GameContext", "GameProtocol", "GamePhase", "GameFailure", "Color", "Vec2", "Rect" };
const public_core_symbol_budget: usize = 9;

comptime {
    if (!withinSurfaceBudget(api.core, public_core_symbol_budget)) @compileError("core API symbol budget exceeded; reduce src/api.zig api.core declarations");
    if (!matchesDeclarationSnapshot(api.core, &expected_declarations)) @compileError("core API snapshot declarations changed; update src/core_api_snapshot.zig intentionally");
    if (!matchesType(api.core.App, app) or !matchesType(api.core.StepClock, app.StepClock) or !matchesType(api.core.GameContext, app.GameContext) or @TypeOf(api.core.GameProtocol) != @TypeOf(app.GameProtocol) or !matchesType(api.core.GamePhase, app.GamePhase) or !matchesType(api.core.GameFailure, app.GameFailure) or !matchesType(api.core.Color, color.Color) or !matchesType(api.core.Vec2, math.Vec2) or !matchesType(api.core.Rect, math.Rect)) @compileError("core API snapshot declaration types changed; update src/core_api_snapshot.zig intentionally");
}

fn withinSurfaceBudget(comptime Surface: type, comptime budget: usize) bool {
    return @typeInfo(Surface).@"struct".decls.len <= budget;
}

fn matchesDeclarationSnapshot(comptime Surface: type, comptime expected: []const []const u8) bool {
    const declarations = @typeInfo(Surface).@"struct".decls;
    if (declarations.len != expected.len) return false;
    inline for (expected, 0..) |name, index| {
        if (!std.mem.eql(u8, declarations[index].name, name)) return false;
    }
    return true;
}

fn matchesType(comptime actual: type, comptime expected: type) bool {
    return actual == expected;
}

test "core API snapshot matcher detects declaration drift" {
    const Surface = struct {
        pub const first = 1;
        pub const second = 2;
    };
    try std.testing.expect(matchesDeclarationSnapshot(Surface, &.{ "first", "second" }));
    try std.testing.expect(!matchesDeclarationSnapshot(Surface, &.{"first"}));
    try std.testing.expect(!matchesDeclarationSnapshot(Surface, &.{ "second", "first" }));
}

test "core API surface budget rejects expansion" {
    const Surface = struct {
        pub const first = 1;
        pub const second = 2;
    };
    try std.testing.expect(withinSurfaceBudget(Surface, 2));
    try std.testing.expect(!withinSurfaceBudget(Surface, 1));
}

test "core API snapshot matcher detects type drift" {
    try std.testing.expect(matchesType(u8, u8));
    try std.testing.expect(!matchesType(u8, u16));
}
