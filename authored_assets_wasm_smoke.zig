const std = @import("std");
const up = @import("unpolished-peas");

const image_bytes = @embedFile("examples/assets/ball.png");
const font_bytes = @embedFile("examples/assets/fonts/Basic-Regular.ttf");

pub export fn up_authored_image_width() u32 {
    var image = up.assets.Image.decode(std.heap.wasm_allocator, image_bytes, .{}) catch return 0;
    defer image.deinit();
    return image.width;
}

pub export fn up_authored_image_hash() u64 {
    var image = up.assets.Image.decode(std.heap.wasm_allocator, image_bytes, .{}) catch return 0;
    defer image.deinit();
    return hashColors(image.pixels);
}

pub export fn up_authored_font_glyph_count() u32 {
    var font = up.assets.Font.decodeTrueType(std.heap.wasm_allocator, font_bytes, .{ .pixel_height = 12, .atlas_width = 128, .atlas_height = 128, .first_codepoint = 32, .codepoint_count = 96 }) catch return 0;
    defer font.deinit();
    return @intCast(font.glyphs.len);
}

pub export fn up_authored_font_canvas_hash() u64 {
    var font = up.assets.Font.decodeTrueType(std.heap.wasm_allocator, font_bytes, .{ .pixel_height = 12, .atlas_width = 128, .atlas_height = 128, .first_codepoint = 32, .codepoint_count = 96 }) catch return 0;
    defer font.deinit();
    var canvas = up.graphics.Canvas.init(std.heap.wasm_allocator, 64, 20) catch return 0;
    defer canvas.deinit();
    canvas.clear(up.core.Color.transparent);
    font.drawText(&canvas, "Peas 42", 1, 1, up.core.Color.white);
    return hashColors(canvas.pixels);
}

fn hashColors(colors: []const up.core.Color) u64 {
    var hash: u64 = 14_695_981_039_346_656_037;
    for (colors) |color| {
        hash ^= color.r;
        hash *%= 1_099_511_628_211;
        hash ^= color.g;
        hash *%= 1_099_511_628_211;
        hash ^= color.b;
        hash *%= 1_099_511_628_211;
        hash ^= color.a;
        hash *%= 1_099_511_628_211;
    }
    return hash;
}
