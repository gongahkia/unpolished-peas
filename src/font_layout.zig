//! Internal implementation of Font's additive authored-text layout API.
const std = @import("std");
const asset = @import("font_asset.zig");
const Alignment = @import("text_layout.zig").Alignment;

pub const Options = struct {
    pub const Wrap = enum { none, word, glyph };
    max_width: ?i32 = null,
    alignment: Alignment = .left,
    wrap: Wrap = .word,
    line_spacing: i32 = 0,
    max_input_bytes: usize = 1024 * 1024,
    max_codepoints: u32 = 65_536,
    max_lines: u32 = 4096,
};

pub const Metrics = struct {
    /// Union of positioned glyph rectangles, including transparent texels.
    /// This is not a tight nontransparent-pixel bounding box.
    pub const Bounds = struct { x: i32, y: i32, width: i32, height: i32 };
    /// Maximum nonnegative final pen advance; includes preserved spaces.
    width: i32 = 0,
    /// Line boxes, including empty hard lines, plus inter-line spacing.
    height: i32 = 0,
    lines: u32 = 0,
    glyph_count: u32 = 0,
    bounds: ?Bounds = null,
    diagnostics: asset.TextDiagnostics = .{},
};

pub const Placement = struct {
    glyph: asset.Glyph,
    /// Local pen coordinates, before the glyph's bearings and font baseline.
    x: i32,
    y: i32,
};

pub const Line = struct {
    /// Byte range in the original text, excluding the terminating LF.
    /// The text itself is not retained or borrowed.
    source_start: usize,
    source_end: usize,
    glyph_start: u32,
    glyph_count: u32,
    x: i32,
    y: i32,
    advance: i32,
};

pub const Error = error{
    InvalidTextLayoutOptions,
    InvalidFontMetrics,
    TextTooLong,
    TooManyCodepoints,
    TooManyTextLines,
    TextLayoutOverflow,
};

const Output = struct { glyphs: []Placement, lines: []Line };
const Rectangle = struct { left: i32, top: i32, right: i32, bottom: i32 };

fn integer(value: i64) Error!i32 {
    return std.math.cast(i32, value) orelse error.TextLayoutOverflow;
}

fn add(a: i32, b: i32) Error!i32 {
    return integer(@as(i64, a) + b);
}

fn unite(current: *?Rectangle, next: Rectangle) void {
    if (current.*) |*value| {
        value.left = @min(value.left, next.left);
        value.top = @min(value.top, next.top);
        value.right = @max(value.right, next.right);
        value.bottom = @max(value.bottom, next.bottom);
    } else current.* = next;
}

const Run = struct {
    font: *const asset.Font,
    options: Options,
    output: ?Output,
    metrics: Metrics = .{},
    codepoints: u32 = 0,
    pen: i32 = 0,
    min_pen: i32 = 0,
    max_pen: i32 = 0,
    y: i32 = 0,
    source_start: usize = 0,
    glyph_start: u32 = 0,
    line_bounds: ?Rectangle = null,
    bounds: ?Rectangle = null,

    fn finishLine(self: *Run, end: usize) Error!void {
        if (self.metrics.lines == self.options.max_lines) return error.TooManyTextLines;
        const offset = if (self.options.max_width) |width| try integer(switch (self.options.alignment) {
            .left => @as(i64, 0),
            .center => @divTrunc(@as(i64, width) - self.pen, 2),
            .right => @as(i64, width) - self.pen,
        }) else 0;
        // Check zero-area glyph placements too, in both analysis passes.
        _ = try add(self.min_pen, offset);
        _ = try add(self.max_pen, offset);
        if (self.line_bounds) |value| {
            unite(&self.bounds, .{ .left = try add(value.left, offset), .right = try add(value.right, offset), .top = value.top, .bottom = value.bottom });
        }
        if (self.output) |out| {
            for (out.glyphs[self.glyph_start..self.metrics.glyph_count]) |*glyph| glyph.x = try add(glyph.x, offset);
            out.lines[self.metrics.lines] = .{
                .source_start = self.source_start,
                .source_end = end,
                .glyph_start = self.glyph_start,
                .glyph_count = self.metrics.glyph_count - self.glyph_start,
                .x = offset,
                .y = self.y,
                .advance = self.pen,
            };
        }
        self.metrics.width = @max(self.metrics.width, self.pen);
        self.metrics.height = try add(self.y, self.font.line_height);
        self.metrics.lines += 1;
    }

    fn nextLine(self: *Run, end: usize, next_start: usize) Error!void {
        try self.finishLine(end);
        self.y = try add(self.y, try add(self.font.line_height, self.options.line_spacing));
        self.pen = 0;
        self.min_pen = 0;
        self.max_pen = 0;
        self.source_start = next_start;
        self.glyph_start = self.metrics.glyph_count;
        self.line_bounds = null;
    }

    fn append(self: *Run, glyph: asset.Glyph) Error!void {
        self.min_pen = @min(self.min_pen, self.pen);
        self.max_pen = @max(self.max_pen, self.pen);
        if (self.output) |out| out.glyphs[self.metrics.glyph_count] = .{ .glyph = glyph, .x = self.pen, .y = self.y };
        self.metrics.glyph_count += 1;
        if (glyph.width != 0 and glyph.height != 0) {
            const left = try add(self.pen, glyph.x_offset);
            const top = try add(try add(self.y, self.font.baseline), glyph.y_offset);
            unite(&self.line_bounds, .{
                .left = left,
                .top = top,
                .right = try integer(@as(i64, left) + glyph.width),
                .bottom = try integer(@as(i64, top) + glyph.height),
            });
        }
        self.pen = try add(self.pen, glyph.advance);
    }

    fn hasGlyphs(self: Run) bool {
        return self.metrics.glyph_count != self.glyph_start;
    }
};

// A word is a run between ASCII spaces or LF. CR is ignored just as in
// Font.drawText. Tabs and other Unicode characters use ordinary glyph/fallback
// metrics; this API does not invent tab stops or Unicode line-breaking rules.
fn wordAdvance(font: *const asset.Font, text: []const u8, start: usize, budget: u32) Error!i64 {
    var index = start;
    var width: i64 = 0;
    var count: u32 = 0;
    while (asset.Font.nextCodepoint(text, &index)) |cp| {
        if (cp == ' ' or cp == '\n') break;
        if (count == budget) return error.TooManyCodepoints;
        count += 1;
        if (cp == '\r') continue;
        if (font.resolveGlyph(cp).glyph) |glyph| width += glyph.advance;
    }
    return width;
}

fn analyze(font: *const asset.Font, text: []const u8, options: Options, output: ?Output) Error!Metrics {
    if (options.max_width) |width| if (width <= 0) return error.InvalidTextLayoutOptions;
    if (options.line_spacing < 0 or options.max_codepoints == 0 or options.max_lines == 0) return error.InvalidTextLayoutOptions;
    if (font.line_height <= 0) return error.InvalidFontMetrics;
    _ = try add(font.line_height, options.line_spacing);
    if (text.len > options.max_input_bytes) return error.TextTooLong;
    var run = Run{ .font = font, .options = options, .output = output };
    var index: usize = 0;
    var active = false;
    var word_start = true;
    while (index < text.len) {
        const start = index;
        const decoded = asset.Font.nextDecodedCodepoint(text, &index).?;
        if (run.codepoints == options.max_codepoints) return error.TooManyCodepoints;
        run.codepoints += 1;
        if (decoded.invalid_utf8) run.metrics.diagnostics.invalid_utf8 += 1;
        const cp = decoded.codepoint;
        if (cp == '\r') continue;
        active = true;
        if (cp == '\n') {
            try run.nextLine(start, index);
            word_start = true;
            continue;
        }
        const resolved = font.resolveGlyph(cp);
        if (resolved.fallback or resolved.glyph == null) run.metrics.diagnostics.missing_glyphs += 1;
        if (resolved.fallback) run.metrics.diagnostics.fallback_glyphs += 1;
        if (options.max_width) |width| {
            if (options.wrap == .word and word_start and cp != ' ') {
                const advance = try wordAdvance(font, text, start, options.max_codepoints - (run.codepoints - 1));
                if (run.hasGlyphs() and @as(i64, run.pen) + advance > width) try run.nextLine(start, start);
            }
            if (options.wrap != .none) {
                if (resolved.glyph) |glyph| {
                    if (run.hasGlyphs() and @as(i64, run.pen) + glyph.advance > width) try run.nextLine(start, start);
                }
            }
        }
        word_start = cp == ' ';
        if (resolved.glyph) |glyph| try run.append(glyph);
    }
    if (active) try run.finishLine(text.len);
    if (run.bounds) |bounds| run.metrics.bounds = .{
        .x = bounds.left,
        .y = bounds.top,
        .width = try integer(@as(i64, bounds.right) - bounds.left),
        .height = try integer(@as(i64, bounds.bottom) - bounds.top),
    };
    return run.metrics;
}

/// Allocation-free analysis with the exact same walker as preparation.
pub fn measure(font: *const asset.Font, text: []const u8, options: Options) Error!Metrics {
    return analyze(font, text, options, null);
}

/// Two passes, then exact retained arrays. No temporary text/glyph buffer and
/// no borrowed input text. The font must remain alive, stable and unchanged.
pub fn prepare(font: *const asset.Font, allocator: std.mem.Allocator, text: []const u8, options: Options) !asset.Font.TextLayout {
    const metrics = try measure(font, text, options);
    const glyphs = try allocator.alloc(Placement, metrics.glyph_count);
    errdefer allocator.free(glyphs);
    const lines = try allocator.alloc(Line, metrics.lines);
    errdefer allocator.free(lines);
    const actual = try analyze(font, text, options, .{ .glyphs = glyphs, .lines = lines });
    return .{ .allocator = allocator, .font = font, .glyphs = glyphs, .lines = lines, .metrics = actual };
}
