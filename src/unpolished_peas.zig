const api = @import("api.zig");

pub const core = api.core;
pub const input = api.input;
pub const graphics = api.graphics;
pub const assets = api.assets;
pub const preview = api.preview;
pub const testSupport = api.testSupport;

test {
    _ = @import("api.zig");
    _ = @import("preview.zig");
    _ = @import("app.zig");
    _ = @import("actions.zig");
    _ = @import("audio.zig");
    _ = @import("atlas.zig");
    _ = @import("camera.zig");
    _ = @import("camera_canvas.zig");
    _ = @import("assets.zig");
    _ = @import("canvas.zig");
    _ = @import("color.zig");
    _ = @import("diagnostics.zig");
    _ = @import("font_asset.zig");
    _ = @import("image.zig");
    _ = @import("input.zig");
    _ = @import("inspector.zig");
    _ = @import("inspector_panels.zig");
    _ = @import("math.zig");
    _ = @import("input_replay.zig");
    _ = @import("presentation.zig");
    _ = @import("primitive_batch.zig");
    _ = @import("render.zig");
    _ = @import("sprite_batch.zig");
    _ = @import("text_layout.zig");
    _ = @import("test_support.zig");
}

test "root module exposes only stable namespaces" {
    inline for (.{ "core", "input", "graphics", "assets", "preview", "testSupport" }) |name| {
        try @import("std").testing.expect(@hasDecl(@This(), name));
    }
    inline for (.{ "Canvas", "Color", "Vec2", "Rect", "App", "AssetStore", "TileMap", "PhysicsWorld", "NetMessage", "PixelEffect" }) |name| {
        try @import("std").testing.expect(!@hasDecl(@This(), name));
    }
}
