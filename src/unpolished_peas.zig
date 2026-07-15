pub const api = @import("api.zig");

test {
    _ = @import("api.zig");
    _ = @import("preview.zig");
    _ = @import("app.zig");
    _ = @import("actions.zig");
    _ = @import("audio.zig");
    _ = @import("broadphase.zig");
    _ = @import("atlas.zig");
    _ = @import("camera.zig");
    _ = @import("camera_canvas.zig");
    _ = @import("assets.zig");
    _ = @import("canvas.zig");
    _ = @import("color.zig");
    _ = @import("diagnostics.zig");
    _ = @import("extension_resolver.zig");
    _ = @import("extension_manifest.zig");
    _ = @import("collision.zig");
    _ = @import("ecs.zig");
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
    _ = @import("tilemap.zig");
    _ = @import("tile_collision.zig");
    _ = @import("text_layout.zig");
    _ = @import("test_support.zig");
}

test "root module exposes only the API namespace" {
    const declarations = @typeInfo(@This()).@"struct".decls;
    try @import("std").testing.expectEqual(@as(usize, 1), declarations.len);
    try @import("std").testing.expectEqualStrings("api", declarations[0].name);
}
