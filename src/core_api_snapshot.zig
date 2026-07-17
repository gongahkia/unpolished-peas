const std = @import("std");
const api = @import("api.zig");
const app = @import("app.zig");
const color = @import("color.zig");
const math = @import("math.zig");
const expected_core = [_][]const u8{ "App", "StepClock", "GameContext", "GameProtocol", "GamePhase", "GameFailure", "Color", "Vec2", "Rect" };
const expected_input = [_][]const u8{ "Input", "Key", "Pointer", "PointerButton", "Gamepad", "GamepadButton", "GamepadAxis", "Action", "ActionBinding", "ActionMap", "InspectorInputPanel" };
const expected_graphics = [_][]const u8{ "Canvas", "Sprite", "ClipRect", "BlendMode", "Camera2D", "CameraCanvas", "Inspector", "InspectorPanel", "InspectorVisibility", "InspectorAssetPanel", "InspectorResource", "InspectorResourceHandle", "Presentation", "PresentationMode", "HeadlessRenderer", "RendererBackend", "FontGlyphRange", "FontTextDiagnostics" };
const expected_assets = [_][]const u8{ "AssetStore", "AssetFile", "AudioHandle", "Image", "Atlas", "AtlasFrameSpec", "AtlasAnimationFrameSpec", "AtlasAnimationSpec", "Font", "Sound", "Music", "AssetStats" };
const expected_preview = [_][]const u8{"developer"};
const expected_preview_developer = [_][]const u8{ "InputReplay", "InputReplayRecorder", "parseInputReplay" };
const expected_test_support = [_][]const u8{ "TempProject", "Clock", "Buttons", "applyTopDownButtons", "frameSeconds", "StateHash", "GoldenOptions", "RendererCaptureTolerance", "cross_backend_renderer_tolerance", "expectRendererCapturesMatch", "RendererConformance", "canvasHash", "assertGolden", "assertReplayHash", "expectError" };
const public_core_symbol_budget: usize = 9;

comptime {
    if (!withinSurfaceBudget(api.core, public_core_symbol_budget)) @compileError("core API symbol budget exceeded; reduce src/api.zig api.core declarations");
    if (!matchesDeclarationSnapshot(api.core, &expected_core) or !matchesDeclarationSnapshot(api.input, &expected_input) or !matchesDeclarationSnapshot(api.graphics, &expected_graphics) or !matchesDeclarationSnapshot(api.assets, &expected_assets) or !matchesDeclarationSnapshot(api.preview, &expected_preview) or !matchesDeclarationSnapshot(api.preview.developer, &expected_preview_developer) or !matchesDeclarationSnapshot(api.testSupport, &expected_test_support)) @compileError("core API snapshot declarations changed; update src/core_api_snapshot.zig intentionally");
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
