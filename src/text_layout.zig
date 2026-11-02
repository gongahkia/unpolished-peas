const std = @import("std");
const font = @import("font.zig");
const Font = @import("font_asset.zig").Font;

pub const Alignment = enum { left, center, right };

pub const Options = struct {
    max_width: ?i32 = null,
    alignment: Alignment = .left,
    line_spacing: i32 = 1,
};

pub const Glyph = struct { codepoint: u21, x: i32, y: i32 };

pub const Layout = struct { // owns glyph storage returned by layout; call deinit once.
    allocator: std.mem.Allocator,
    glyphs: []Glyph,
    width: i32,
    height: i32,
    lines: u32,

    pub fn deinit(self: *Layout) void {
        self.allocator.free(self.glyphs);
        self.* = undefined;
    }
};

pub fn layout(allocator: std.mem.Allocator, text: []const u8, options: Options) !Layout {
    var glyphs = std.ArrayList(Glyph).empty;
    errdefer glyphs.deinit(allocator);
    const advance: i32 = font.width + 1;
    const line_height: i32 = font.height + options.line_spacing;
    var index: usize = 0;
    var x: i32 = 0;
    var y: i32 = 0;
    var width: i32 = 0;
    var line_start: usize = 0;
    var lines: u32 = 1;
    while (Font.nextCodepoint(text, &index)) |codepoint| {
        if (codepoint == '\n') {
            alignLine(glyphs.items[line_start..], x - advance, options);
            width = @max(width, x - advance);
            line_start = glyphs.items.len;
            x = 0;
            y += line_height;
            lines += 1;
            continue;
        }
        if (options.max_width) |max_width| if (x > 0 and x + advance > max_width) {
            alignLine(glyphs.items[line_start..], x - advance, options);
            width = @max(width, x - advance);
            line_start = glyphs.items.len;
            x = 0;
            y += line_height;
            lines += 1;
        };
        try glyphs.append(allocator, .{ .codepoint = codepoint, .x = x, .y = y });
        x += advance;
    }
    const final_width = if (x == 0) 0 else x - advance;
    alignLine(glyphs.items[line_start..], final_width, options);
    width = @max(width, final_width);
    return .{ .allocator = allocator, .glyphs = try glyphs.toOwnedSlice(allocator), .width = width, .height = @as(i32, @intCast(lines)) * line_height - options.line_spacing, .lines = lines };
}

fn alignLine(glyphs: []Glyph, width: i32, options: Options) void {
    const target = options.max_width orelse return;
    const offset = switch (options.alignment) {
        .left => 0,
        .center => @divTrunc(target - width, 2),
        .right => target - width,
    };
    for (glyphs) |*glyph| glyph.x += offset;
}

test "layout uses strict deterministic UTF-8 replacement" {
    const invalid = [_]u8{ 'A', 0xc0, 0x80, 'B' };
    var result = try layout(std.testing.allocator, &invalid, .{ .max_width = 18, .alignment = .center });
    defer result.deinit();
    try std.testing.expectEqual(@as(u32, 1), result.lines);
    try std.testing.expectEqual(@as(usize, 3), result.glyphs.len);
    try std.testing.expectEqual(@as(u21, 0xfffd), result.glyphs[1].codepoint);
    try std.testing.expectEqual(@as(i32, 3), result.glyphs[0].x);
}
