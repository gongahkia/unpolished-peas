const std = @import("std");
const Sampling = @import("atlas.zig").Sampling;
const Canvas = @import("canvas.zig").Canvas;
const Color = @import("color.zig").Color;
const Image = @import("image.zig").Image;

const max_atlas_dimension = 4096;
const max_glyph_count = 65_535;

const PackedChar = extern struct {
    x0: u16,
    y0: u16,
    x1: u16,
    y1: u16,
    xoff: f32,
    yoff: f32,
    xadvance: f32,
    xoff2: f32,
    yoff2: f32,
};

const PackedRange = extern struct {
    first_codepoint: c_int,
    count: c_int,
    glyphs: [*]PackedChar,
    present: [*]u8,
};

extern fn up_pack_font_ranges(data: [*]const u8, pixel_height: c_int, pixels: [*]u8, width: c_int, height: c_int, ranges: [*]const PackedRange, range_count: c_int) c_int;

pub const LoadOptions = struct {
    pixel_height: u16 = 20,
    atlas_width: u32 = 512,
    atlas_height: u32 = 512,
    first_codepoint: u21 = 32,
    codepoint_count: u16 = 224,
    ranges: []const GlyphRange = &.{},
    fallback_codepoint: ?u21 = '?',
};

pub const GlyphRange = struct {
    first_codepoint: u21,
    codepoint_count: u16,
};

pub const Glyph = struct {
    codepoint: u21,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    x_offset: i32,
    y_offset: i32,
    advance: i32,
};

pub const TextDiagnostics = struct {
    invalid_utf8: u32 = 0,
    missing_glyphs: u32 = 0,
    fallback_glyphs: u32 = 0,
};

pub const DecodedCodepoint = struct {
    codepoint: u21,
    invalid_utf8: bool,
};

pub const Font = struct { // owns atlas pixels and glyph storage allocated by decode; call deinit once.
    allocator: std.mem.Allocator,
    image: Image,
    glyphs: []Glyph,
    line_height: i32,
    baseline: i32,
    sampling: Sampling,
    fallback_codepoint: ?u21 = '?',

    pub fn decodeTrueType(allocator: std.mem.Allocator, bytes: []const u8, options: LoadOptions) !Font {
        try validateOptions(options);
        if (bytes.len == 0) return error.InvalidFontData;
        var ranges = std.ArrayListUnmanaged(GlyphRange){};
        defer ranges.deinit(allocator);
        if (options.ranges.len == 0) {
            try ranges.append(allocator, .{ .first_codepoint = options.first_codepoint, .codepoint_count = options.codepoint_count });
        } else {
            try ranges.appendSlice(allocator, options.ranges);
        }
        if (options.fallback_codepoint) |codepoint| if (!containsCodepoint(ranges.items, codepoint)) {
            try ranges.append(allocator, .{ .first_codepoint = codepoint, .codepoint_count = 1 });
        };
        try validateRanges(ranges.items);

        const pixel_count = std.math.mul(usize, options.atlas_width, options.atlas_height) catch return error.FontAtlasTooLarge;
        const alpha = try allocator.alloc(u8, pixel_count);
        defer allocator.free(alpha);
        @memset(alpha, 0);

        const glyph_count = try totalGlyphCount(ranges.items);
        const packed_glyphs = try allocator.alloc(PackedChar, glyph_count);
        defer allocator.free(packed_glyphs);
        const presence = try allocator.alloc(u8, glyph_count);
        defer allocator.free(presence);
        const packed_ranges = try allocator.alloc(PackedRange, ranges.items.len);
        defer allocator.free(packed_ranges);
        var offset: usize = 0;
        for (ranges.items, 0..) |range, range_index| {
            const count: usize = range.codepoint_count;
            packed_ranges[range_index] = .{
                .first_codepoint = @intCast(range.first_codepoint),
                .count = @intCast(range.codepoint_count),
                .glyphs = packed_glyphs[offset..].ptr,
                .present = presence[offset..].ptr,
            };
            offset += count;
        }
        if (up_pack_font_ranges(bytes.ptr, @intCast(options.pixel_height), alpha.ptr, @intCast(options.atlas_width), @intCast(options.atlas_height), packed_ranges.ptr, @intCast(packed_ranges.len)) == 0) return error.FontAtlasTooSmall;

        const pixels = try allocator.alloc(Color, pixel_count);
        errdefer allocator.free(pixels);
        for (alpha, 0..) |value, index| pixels[index] = Color.rgba(255, 255, 255, value);
        var image = Image{ .allocator = allocator, .width = options.atlas_width, .height = options.atlas_height, .pixels = pixels };
        errdefer image.deinit();

        var glyphs = std.ArrayListUnmanaged(Glyph){};
        errdefer glyphs.deinit(allocator);
        var top: f32 = 0;
        var bottom: f32 = 0;
        offset = 0;
        for (ranges.items) |range| {
            const count: usize = range.codepoint_count;
            for (packed_glyphs[offset .. offset + count], presence[offset .. offset + count], 0..) |glyph, present, index| {
                if (present == 0) continue;
                const width = glyph.x1 - glyph.x0;
                const height = glyph.y1 - glyph.y0;
                try glyphs.append(allocator, .{
                    .codepoint = range.first_codepoint + @as(u21, @intCast(index)),
                    .x = glyph.x0,
                    .y = glyph.y0,
                    .width = width,
                    .height = height,
                    .x_offset = floorI32(glyph.xoff),
                    .y_offset = floorI32(glyph.yoff),
                    .advance = @max(0, roundI32(glyph.xadvance)),
                });
                if (width != 0 and height != 0) {
                    top = @min(top, glyph.yoff);
                    bottom = @max(bottom, glyph.yoff + @as(f32, @floatFromInt(height)));
                }
            }
            offset += count;
        }
        const owned_glyphs = try glyphs.toOwnedSlice(allocator);
        errdefer allocator.free(owned_glyphs);
        const baseline = @max(0, floorI32(-top));
        const line_height = @max(@as(i32, @intCast(options.pixel_height)), baseline + @max(0, ceilI32(bottom)));
        return .{ .allocator = allocator, .image = image, .glyphs = owned_glyphs, .line_height = line_height, .baseline = baseline, .sampling = .linear, .fallback_codepoint = options.fallback_codepoint };
    }

    pub fn bitmapImagePath(allocator: std.mem.Allocator, descriptor: []const u8) ![]u8 {
        var lines = std.mem.splitScalar(u8, descriptor, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (!std.mem.startsWith(u8, line, "page ")) continue;
            const id = try parseI32(fieldValue(line, "id") orelse return error.InvalidBitmapFont);
            if (id != 0) continue;
            return allocator.dupe(u8, fieldValue(line, "file") orelse return error.InvalidBitmapFont);
        }
        return error.MissingBitmapFontPage;
    }

    pub fn decodeBitmap(allocator: std.mem.Allocator, descriptor: []const u8, image_bytes: []const u8) !Font {
        var image = try Image.decode(allocator, image_bytes, .{});
        errdefer image.deinit();
        var glyphs = std.ArrayListUnmanaged(Glyph){};
        errdefer glyphs.deinit(allocator);
        var line_height: ?i32 = null;
        var lines = std.mem.splitScalar(u8, descriptor, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (std.mem.startsWith(u8, line, "common ")) {
                const value = try parseI32(fieldValue(line, "lineHeight") orelse return error.InvalidBitmapFont);
                if (value <= 0 or value > max_atlas_dimension) return error.InvalidBitmapFont;
                line_height = value;
                continue;
            }
            if (!std.mem.startsWith(u8, line, "char ")) continue;
            const raw_codepoint = try parseI64(fieldValue(line, "id") orelse return error.InvalidBitmapFont);
            if (raw_codepoint < 0 or raw_codepoint > std.math.maxInt(u21)) return error.InvalidBitmapFont;
            const codepoint: u21 = @intCast(raw_codepoint);
            for (glyphs.items) |glyph| if (glyph.codepoint == codepoint) return error.DuplicateBitmapGlyph;
            const x = try parseI32(fieldValue(line, "x") orelse return error.InvalidBitmapFont);
            const y = try parseI32(fieldValue(line, "y") orelse return error.InvalidBitmapFont);
            const width = try parseI32(fieldValue(line, "width") orelse return error.InvalidBitmapFont);
            const height = try parseI32(fieldValue(line, "height") orelse return error.InvalidBitmapFont);
            if (x < 0 or y < 0 or width < 0 or height < 0) return error.InvalidBitmapFont;
            if (@as(i64, x) + width > image.width or @as(i64, y) + height > image.height) return error.BitmapGlyphOutsideImage;
            const x_offset = try parseI32(fieldValue(line, "xoffset") orelse return error.InvalidBitmapFont);
            const y_offset = try parseI32(fieldValue(line, "yoffset") orelse return error.InvalidBitmapFont);
            const advance = try parseI32(fieldValue(line, "xadvance") orelse return error.InvalidBitmapFont);
            if (!validMetric(x_offset) or !validMetric(y_offset) or !validMetric(advance)) return error.InvalidBitmapFont;
            try glyphs.append(allocator, .{
                .codepoint = codepoint,
                .x = @intCast(x),
                .y = @intCast(y),
                .width = @intCast(width),
                .height = @intCast(height),
                .x_offset = x_offset,
                .y_offset = y_offset,
                .advance = advance,
            });
        }
        const resolved_line_height = line_height orelse return error.InvalidBitmapFont;
        return .{ .allocator = allocator, .image = image, .glyphs = try glyphs.toOwnedSlice(allocator), .line_height = resolved_line_height, .baseline = 0, .sampling = .nearest };
    }

    pub fn deinit(self: *Font) void {
        self.image.deinit();
        self.allocator.free(self.glyphs);
        self.* = undefined;
    }

    pub fn glyphForCodepoint(self: *const Font, codepoint: u21) ?Glyph {
        return self.resolveGlyph(codepoint).glyph;
    }

    pub fn resolveGlyph(self: *const Font, codepoint: u21) struct { glyph: ?Glyph, fallback: bool } {
        for (self.glyphs) |glyph| if (glyph.codepoint == codepoint) return .{ .glyph = glyph, .fallback = false };
        if (self.fallback_codepoint) |fallback_codepoint| if (codepoint != fallback_codepoint) {
            for (self.glyphs) |glyph| if (glyph.codepoint == fallback_codepoint) return .{ .glyph = glyph, .fallback = true };
        };
        return .{ .glyph = null, .fallback = false };
    }

    pub fn nextCodepoint(text: []const u8, index: *usize) ?u21 {
        const decoded = nextDecodedCodepoint(text, index) orelse return null;
        return decoded.codepoint;
    }

    pub fn nextDecodedCodepoint(text: []const u8, index: *usize) ?DecodedCodepoint {
        return decodeNextCodepoint(text, index);
    }

    pub fn textDiagnostics(self: *const Font, text: []const u8) TextDiagnostics {
        var diagnostics = TextDiagnostics{};
        var index: usize = 0;
        while (nextDecodedCodepoint(text, &index)) |decoded| {
            if (decoded.invalid_utf8) diagnostics.invalid_utf8 += 1;
            if (decoded.codepoint == '\r' or decoded.codepoint == '\n') continue;
            const resolved = self.resolveGlyph(decoded.codepoint);
            if (!resolved.fallback and resolved.glyph != null) continue;
            diagnostics.missing_glyphs += 1;
            if (resolved.fallback) diagnostics.fallback_glyphs += 1;
        }
        return diagnostics;
    }

    pub fn drawText(self: *const Font, canvas: *Canvas, text: []const u8, x: i32, y: i32, color: Color) void {
        var index: usize = 0;
        var pen_x = x;
        var pen_y = y;
        while (nextCodepoint(text, &index)) |codepoint| {
            if (codepoint == '\r') continue;
            if (codepoint == '\n') {
                pen_x = x;
                pen_y = saturatingAdd(pen_y, self.line_height);
                continue;
            }
            if (self.resolveGlyph(codepoint).glyph) |glyph| {
                self.drawGlyph(canvas, glyph, pen_x, pen_y, color);
                pen_x = saturatingAdd(pen_x, glyph.advance);
            }
        }
    }

    fn drawGlyph(self: *const Font, canvas: *Canvas, glyph: Glyph, pen_x: i32, pen_y: i32, color: Color) void {
        var local_y: u32 = 0;
        while (local_y < glyph.height) : (local_y += 1) {
            var local_x: u32 = 0;
            while (local_x < glyph.width) : (local_x += 1) {
                const source = self.image.pixels[@as(usize, glyph.y + local_y) * self.image.width + glyph.x + local_x];
                if (source.a != 0) canvas.pixel(saturatingAdd(saturatingAdd(pen_x, glyph.x_offset), @intCast(local_x)), saturatingAdd(saturatingAdd(saturatingAdd(pen_y, self.baseline), glyph.y_offset), @intCast(local_y)), tint(source, color));
            }
        }
    }
};

fn decodeNextCodepoint(text: []const u8, index: *usize) ?DecodedCodepoint {
    if (index.* >= text.len) return null;
    const first = text[index.*];
    if (first < 0x80) {
        index.* += 1;
        return .{ .codepoint = first, .invalid_utf8 = false };
    }
    const length: usize = if ((first & 0xe0) == 0xc0) 2 else if ((first & 0xf0) == 0xe0) 3 else if ((first & 0xf8) == 0xf0) 4 else 1;
    if (length == 1 or index.* + length > text.len) {
        index.* += 1;
        return .{ .codepoint = 0xfffd, .invalid_utf8 = true };
    }
    const minimum: u21 = switch (length) {
        2 => 0x80,
        3 => 0x800,
        4 => 0x10000,
        else => unreachable,
    };
    var codepoint: u21 = first & (@as(u8, 0x7f) >> @intCast(length));
    var offset: usize = 1;
    while (offset < length) : (offset += 1) {
        const byte = text[index.* + offset];
        if ((byte & 0xc0) != 0x80) {
            index.* += 1;
            return .{ .codepoint = 0xfffd, .invalid_utf8 = true };
        }
        codepoint = (codepoint << 6) | (byte & 0x3f);
    }
    index.* += length;
    if (codepoint < minimum or codepoint > 0x10ffff or (codepoint >= 0xd800 and codepoint <= 0xdfff)) return .{ .codepoint = 0xfffd, .invalid_utf8 = true };
    return .{ .codepoint = codepoint, .invalid_utf8 = false };
}

fn validateOptions(options: LoadOptions) !void {
    if (options.pixel_height == 0 or options.atlas_width == 0 or options.atlas_height == 0 or options.codepoint_count == 0) return error.InvalidFontOptions;
    if (options.atlas_width > max_atlas_dimension or options.atlas_height > max_atlas_dimension) return error.FontAtlasTooLarge;
    try validateRange(.{ .first_codepoint = options.first_codepoint, .codepoint_count = options.codepoint_count });
    if (options.ranges.len != 0) try validateRanges(options.ranges);
    if (options.fallback_codepoint) |codepoint| if (!isUnicodeScalar(codepoint)) return error.InvalidFontOptions;
}

fn totalGlyphCount(ranges: []const GlyphRange) !usize {
    var total: usize = 0;
    for (ranges) |range| {
        total = std.math.add(usize, total, range.codepoint_count) catch return error.FontAtlasTooLarge;
        if (total > max_glyph_count) return error.FontAtlasTooLarge;
    }
    return total;
}

fn containsCodepoint(ranges: []const GlyphRange, codepoint: u21) bool {
    for (ranges) |range| {
        const end = @as(u32, range.first_codepoint) + range.codepoint_count - 1;
        if (codepoint >= range.first_codepoint and codepoint <= end) return true;
    }
    return false;
}

fn validateRanges(ranges: []const GlyphRange) !void {
    if (ranges.len == 0) return error.InvalidFontOptions;
    for (ranges, 0..) |range, index| {
        try validateRange(range);
        const range_end = @as(u32, range.first_codepoint) + range.codepoint_count - 1;
        for (ranges[index + 1 ..]) |other| {
            const other_end = @as(u32, other.first_codepoint) + other.codepoint_count - 1;
            if (range.first_codepoint <= other_end and other.first_codepoint <= range_end) return error.InvalidFontOptions;
        }
    }
}

fn validateRange(range: GlyphRange) !void {
    if (range.codepoint_count == 0) return error.InvalidFontOptions;
    const end = @as(u32, range.first_codepoint) + range.codepoint_count - 1;
    if (end > 0x10ffff or !isUnicodeScalar(range.first_codepoint) or (range.first_codepoint <= 0xdfff and end >= 0xd800)) return error.InvalidFontOptions;
}

fn isUnicodeScalar(codepoint: u21) bool {
    return codepoint <= 0x10ffff and (codepoint < 0xd800 or codepoint > 0xdfff);
}

fn fieldValue(line: []const u8, key: []const u8) ?[]const u8 {
    var index: usize = 0;
    while (index < line.len) {
        while (index < line.len and (line[index] == ' ' or line[index] == '\t')) : (index += 1) {}
        const name_start = index;
        while (index < line.len and line[index] != '=' and line[index] != ' ' and line[index] != '\t') : (index += 1) {}
        if (index == line.len or line[index] != '=') {
            while (index < line.len and line[index] != ' ' and line[index] != '\t') : (index += 1) {}
            continue;
        }
        const name = line[name_start..index];
        index += 1;
        const value = if (index < line.len and line[index] == '"') blk: {
            index += 1;
            const start = index;
            while (index < line.len and line[index] != '"') : (index += 1) {}
            if (index == line.len) return null;
            const out = line[start..index];
            index += 1;
            break :blk out;
        } else blk: {
            const start = index;
            while (index < line.len and line[index] != ' ' and line[index] != '\t') : (index += 1) {}
            break :blk line[start..index];
        };
        if (std.mem.eql(u8, name, key)) return value;
    }
    return null;
}

fn parseI32(value: []const u8) !i32 {
    return std.fmt.parseInt(i32, value, 10) catch error.InvalidBitmapFont;
}

fn parseI64(value: []const u8) !i64 {
    return std.fmt.parseInt(i64, value, 10) catch error.InvalidBitmapFont;
}

fn validMetric(value: i32) bool {
    return value >= -max_atlas_dimension and value <= max_atlas_dimension;
}

fn saturatingAdd(a: i32, b: i32) i32 {
    return std.math.add(i32, a, b) catch if (b < 0) std.math.minInt(i32) else std.math.maxInt(i32);
}

fn floorI32(value: f32) i32 {
    return @intFromFloat(@floor(value));
}

fn ceilI32(value: f32) i32 {
    return @intFromFloat(@ceil(value));
}

fn roundI32(value: f32) i32 {
    return @intFromFloat(@round(value));
}

fn tint(source: Color, value: Color) Color {
    return Color.rgba(
        @intCast(@as(u16, source.r) * value.r / 255),
        @intCast(@as(u16, source.g) * value.g / 255),
        @intCast(@as(u16, source.b) * value.b / 255),
        @intCast(@as(u16, source.a) * value.a / 255),
    );
}

test "bitmap fonts parse quoted page paths and glyph metrics" {
    const descriptor =
        "common lineHeight=8 base=7 scaleW=1 scaleH=1 pages=1\n" ++
        "page id=0 file=\"fixture atlas.png\"\n" ++
        "chars count=1\n" ++
        "char id=65 x=0 y=0 width=1 height=1 xoffset=1 yoffset=2 xadvance=3\n";
    const path = try Font.bitmapImagePath(std.testing.allocator, descriptor);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("fixture atlas.png", path);
    const png = try std.fs.cwd().readFileAlloc(std.testing.allocator, "examples/assets/ball.png", 1024 * 1024);
    defer std.testing.allocator.free(png);
    var font = try Font.decodeBitmap(std.testing.allocator, descriptor, png);
    defer font.deinit();
    const glyph = font.glyphForCodepoint('A').?;
    try std.testing.expectEqual(@as(i32, 3), glyph.advance);
    try std.testing.expectEqual(@as(i32, 2), glyph.y_offset);
}

test "font atlases pack Unicode ranges and report fallback diagnostics" {
    const bytes = try std.fs.cwd().readFileAlloc(std.testing.allocator, "examples/assets/fonts/SourceSans3-Regular.otf", 32 * 1024 * 1024);
    defer std.testing.allocator.free(bytes);
    var font = try Font.decodeTrueType(std.testing.allocator, bytes, .{
        .ranges = &.{
            .{ .first_codepoint = 'A', .codepoint_count = 1 },
            .{ .first_codepoint = 0x00c9, .codepoint_count = 1 },
            .{ .first_codepoint = 0x0378, .codepoint_count = 1 },
        },
    });
    defer font.deinit();

    try std.testing.expect(!font.resolveGlyph('A').fallback);
    try std.testing.expect(!font.resolveGlyph(0x00c9).fallback);
    const diagnostics = font.textDiagnostics(&.{ 'A', 0xe4, 0xb8, 0x80, 0xc0, 0x80 });
    try std.testing.expectEqual(@as(u32, 1), diagnostics.invalid_utf8);
    try std.testing.expectEqual(@as(u32, 2), diagnostics.missing_glyphs);
    try std.testing.expectEqual(@as(u32, 2), diagnostics.fallback_glyphs);
    try std.testing.expectError(error.InvalidFontOptions, Font.decodeTrueType(std.testing.allocator, "", .{
        .ranges = &.{
            .{ .first_codepoint = 0x0040, .codepoint_count = 2 },
            .{ .first_codepoint = 0x0041, .codepoint_count = 1 },
        },
    }));
}

test "font UTF-8 decoding replaces malformed sequences" {
    const invalid = [_]u8{ 'A', 0xff, 0xc0, 0x80, 'B' };
    var index: usize = 0;
    try std.testing.expectEqual(@as(?u21, 'A'), Font.nextCodepoint(&invalid, &index));
    try std.testing.expectEqual(@as(?u21, 0xfffd), Font.nextCodepoint(&invalid, &index));
    try std.testing.expectEqual(@as(?u21, 0xfffd), Font.nextCodepoint(&invalid, &index));
    try std.testing.expectEqual(@as(?u21, 'B'), Font.nextCodepoint(&invalid, &index));
}
