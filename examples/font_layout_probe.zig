//! Native/Wasm measurements and independent pixel checks for authored layout.
const std = @import("std");
const builtin = @import("builtin");
const up = @import("unpolished-peas");
const Font = up.assets.Font;
const Color = up.core.Color;
const source_sans = @embedFile("assets/fonts/SourceSans3-Regular.otf");
const basic = @embedFile("assets/fonts/Basic-Regular.ttf");
const invalid = [_]u8{ 'W', 0xc0, 0x80, 0xff, 'i' };
const menu = @import("font_layout_game.zig");

const Counter = struct {
    parent: std.mem.Allocator,
    operations: usize = 0,
    fn allocator(self: *Counter) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        self.operations += 1;
        return self.parent.rawAlloc(len, alignment, ret);
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) bool {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        self.operations += 1;
        return self.parent.rawResize(memory, alignment, len, ret);
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) ?[*]u8 {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        self.operations += 1;
        return self.parent.rawRemap(memory, alignment, len, ret);
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        self.operations += 1;
        self.parent.rawFree(memory, alignment, ret);
    }
};

// A borrowed stack fixture: never deinitialize this view as an owned Font.
// Metrics cover proportional advances, bearings/baseline, zero-area spaces,
// fallback, Unicode and a valid signed bitmap-font advance.
const Fixture = struct {
    pixels: [16]Color = .{Color.rgba(180, 100, 60, 191)} ** 16,
    glyphs: [6]up.assets.FontGlyph = .{
        .{ .codepoint = 'W', .x = 0, .y = 0, .width = 3, .height = 2, .x_offset = -1, .y_offset = -3, .advance = 5 },
        .{ .codepoint = 'i', .x = 3, .y = 0, .width = 1, .height = 2, .x_offset = 0, .y_offset = -2, .advance = 2 },
        .{ .codepoint = ' ', .x = 0, .y = 0, .width = 0, .height = 0, .x_offset = 0, .y_offset = 0, .advance = 1 },
        .{ .codepoint = '?', .x = 4, .y = 0, .width = 2, .height = 2, .x_offset = 1, .y_offset = -2, .advance = 3 },
        .{ .codepoint = 0x00c9, .x = 6, .y = 0, .width = 1, .height = 2, .x_offset = -1, .y_offset = -4, .advance = 4 },
        .{ .codepoint = 'z', .x = 7, .y = 0, .width = 1, .height = 2, .x_offset = 0, .y_offset = -2, .advance = -1 },
    },
    fn font(self: *Fixture, allocator: std.mem.Allocator) Font {
        return .{ .allocator = allocator, .image = .{ .allocator = allocator, .width = 8, .height = 2, .pixels = &self.pixels }, .glyphs = &self.glyphs, .line_height = 7, .baseline = 3, .sampling = .nearest };
    }
};

fn check(value: bool) !void {
    if (!value) return error.FontLayoutConformanceMismatch;
}

const Report = struct { cases: u32 = 0, pixel_hash: u64 = 0, metrics_hash: u64 = 0, legacy_www: i32 = 0, authored_www: i32 = 0, authored_iii: i32 = 0 };
var report: Report = .{};
var failed_case: u32 = 0;
var failed_pixel: u32 = 0;

fn fold(hash: *std.hash.Fnv1a_64, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}
fn signed(value: i32) u64 {
    return @as(u32, @bitCast(value));
}
fn foldMetrics(hash: *std.hash.Fnv1a_64, layout: *const Font.TextLayout) void {
    fold(hash, signed(layout.metrics.width));
    fold(hash, signed(layout.metrics.height));
    fold(hash, layout.metrics.lines);
    fold(hash, layout.metrics.glyph_count);
    fold(hash, layout.metrics.diagnostics.invalid_utf8);
    fold(hash, layout.metrics.diagnostics.missing_glyphs);
    fold(hash, layout.metrics.diagnostics.fallback_glyphs);
    fold(hash, @intFromBool(layout.metrics.bounds != null));
    if (layout.metrics.bounds) |b| for ([_]i32{ b.x, b.y, b.width, b.height }) |n| fold(hash, signed(n));
    for (layout.lines) |line| {
        fold(hash, line.source_start);
        fold(hash, line.source_end);
        fold(hash, line.glyph_start);
        fold(hash, line.glyph_count);
        fold(hash, signed(line.x));
        fold(hash, signed(line.y));
        fold(hash, signed(line.advance));
    }
    for (layout.glyphs) |glyph| {
        fold(hash, glyph.glyph.codepoint);
        fold(hash, signed(glyph.x));
        fold(hash, signed(glyph.y));
    }
}

fn pixelsEqual(actual: *const up.graphics.Canvas, expected: *const up.graphics.Canvas) !void {
    for (actual.pixels, expected.pixels, 0..) |a, b, index| if (!std.meta.eql(a, b)) {
        failed_pixel = @intCast(index);
        return error.FontLayoutPixelMismatch;
    };
}

fn rejected(allocator: std.mem.Allocator, font: *const Font, text: []const u8, options: Font.TextOptions, expected: anyerror) !void {
    if (font.measureText(text, options)) |_| return error.ExpectedLayoutRejection else |err| try check(err == expected);
    if (font.layoutText(allocator, text, options)) |value| {
        var owned = value;
        owned.deinit();
        return error.ExpectedLayoutRejection;
    } else |err| try check(err == expected);
}

fn limits(allocator: std.mem.Allocator) !void {
    var fixture = Fixture{};
    var font = fixture.font(allocator);
    try rejected(allocator, &font, "W", .{ .max_width = 0 }, error.InvalidTextLayoutOptions);
    try rejected(allocator, &font, "", .{ .max_width = -1, .wrap = .none }, error.InvalidTextLayoutOptions);
    try rejected(allocator, &font, "", .{ .line_spacing = -1 }, error.InvalidTextLayoutOptions);
    try rejected(allocator, &font, "", .{ .max_lines = 0 }, error.InvalidTextLayoutOptions);
    try rejected(allocator, &font, "", .{ .max_codepoints = 0 }, error.InvalidTextLayoutOptions);
    try rejected(allocator, &font, "É", .{ .max_input_bytes = 1 }, error.TextTooLong);
    try rejected(allocator, &font, "\rW", .{ .max_codepoints = 1 }, error.TooManyCodepoints);
    try rejected(allocator, &font, "iiiiii", .{ .max_codepoints = 3, .max_width = 8 }, error.TooManyCodepoints);
    try rejected(allocator, &font, "W\n", .{ .max_lines = 1 }, error.TooManyTextLines);
    try rejected(allocator, &font, "", .{ .line_spacing = std.math.maxInt(i32) }, error.TextLayoutOverflow);
    try rejected(allocator, &font, "zz", .{ .max_width = std.math.maxInt(i32), .wrap = .none, .alignment = .right }, error.TextLayoutOverflow);
    try check((try font.measureText("É", .{ .max_codepoints = 1, .max_input_bytes = 2 })).glyph_count == 1);
    try check((try font.measureText("i i", .{ .max_codepoints = 3, .max_width = 8 })).lines == 1);
    font.line_height = 0;
    try rejected(allocator, &font, "", .{}, error.InvalidFontMetrics);
    font.line_height = 7;
    fixture.glyphs[0].advance = std.math.maxInt(i32);
    try rejected(allocator, &font, "WW", .{}, error.TextLayoutOverflow);
    fixture.glyphs[1].advance = -std.math.maxInt(i32);
    fixture.glyphs[0].width = 0;
    fixture.glyphs[1].width = 0;
    try rejected(allocator, &font, "Wi", .{ .max_width = std.math.maxInt(i32), .wrap = .none, .alignment = .right }, error.TextLayoutOverflow);
}

fn inputOwnership(allocator: std.mem.Allocator) !void {
    var fixture = Fixture{};
    const font = fixture.font(allocator);
    var counter = Counter{ .parent = allocator };
    const text = try allocator.dupe(u8, "Wi");
    var prepared = font.layoutText(counter.allocator(), text, .{}) catch |err| {
        allocator.free(text);
        return err;
    };
    defer prepared.deinit();
    allocator.free(text);
    var actual = try up.graphics.Canvas.init(counter.allocator(), 24, 16);
    defer actual.deinit();
    var expected = try up.graphics.Canvas.init(allocator, 24, 16);
    defer expected.deinit();
    for (0..3) |_| {
        actual.clear(Color.transparent);
        expected.clear(Color.transparent);
        counter.operations = 0;
        prepared.draw(&actual, 8, 5, Color.white);
        try check(counter.operations == 0);
        font.drawText(&expected, "Wi", 8, 5, Color.white);
        try pixelsEqual(&actual, &expected);
    }
}

// Oracle: unchanged Font.drawText on independently specified lines.
// Expected line boundaries/advances never come from the prepared layout.
fn pixelCase(allocator: std.mem.Allocator, font: *const Font, text: []const u8, options: Font.TextOptions, expected_lines: []const []const u8, phase: u32, pixel_hash: *std.hash.Fnv1a_64, metric_hash: *std.hash.Fnv1a_64) !void {
    var counter = Counter{ .parent = allocator };
    // Borrow these arrays; never deinitialize this instrumented view.
    var counted_font = font.*;
    counted_font.allocator = counter.allocator();
    counted_font.image.allocator = counter.allocator();
    var actual = try up.graphics.Canvas.init(counter.allocator(), 80, 54);
    defer actual.deinit();
    var expected = try up.graphics.Canvas.init(allocator, 80, 54);
    defer expected.deinit();
    counter.operations = 0;
    const measured = try counted_font.measureText(text, options);
    try check(counter.operations == 0);
    var prepared = try counted_font.layoutText(counter.allocator(), text, options);
    defer prepared.deinit();
    try check(std.meta.eql(measured, prepared.metrics));
    try check(std.meta.eql(measured.diagnostics, font.textDiagnostics(text)));
    try check(prepared.lines.len == expected_lines.len);
    const x: i32 = if (phase % 2 == 0) -2 else 4;
    const y: i32 = if (phase % 3 == 0) -1 else 3;
    const color = Color.rgba(119, 203, 87, 157);
    actual.clear(Color.rgba(13, 27, 51, 73));
    expected.clear(Color.rgba(13, 27, 51, 73));
    const blend: up.graphics.BlendMode = if (phase % 2 == 0) .alpha else .additive;
    _ = actual.setBlend(blend);
    _ = expected.setBlend(blend);
    if (phase % 3 == 0) {
        _ = actual.pushClip(.{ .x = 1, .y = 2, .w = 61, .h = 43 });
        _ = expected.pushClip(.{ .x = 1, .y = 2, .w = 61, .h = 43 });
    }
    counter.operations = 0;
    prepared.draw(&actual, x, y, color);
    try check(counter.operations == 0);
    var logical_width: i32 = 0;
    var source_cursor: usize = 0;
    for (expected_lines, 0..) |line, line_index| {
        try check(prepared.lines[line_index].source_start == source_cursor);
        try check(prepared.lines[line_index].source_end == source_cursor + line.len);
        try check(std.mem.eql(u8, text[source_cursor..][0..line.len], line));
        source_cursor += line.len;
        if (source_cursor < text.len and text[source_cursor] == '\n') source_cursor += 1;
        var advance: i32 = 0;
        var i: usize = 0;
        while (Font.nextCodepoint(line, &i)) |cp| {
            if (cp == '\r' or cp == '\n') continue;
            if (font.resolveGlyph(cp).glyph) |glyph| advance += glyph.advance;
        }
        logical_width = @max(logical_width, advance);
        const offset = if (options.max_width) |width| switch (options.alignment) {
            .left => 0,
            .center => @divTrunc(width - advance, 2),
            .right => width - advance,
        } else 0;
        const line_y = @as(i32, @intCast(line_index)) * (font.line_height + options.line_spacing);
        font.drawText(&expected, line, x + offset, y + line_y, color);
        try check(prepared.lines[line_index].advance == advance);
        try check(prepared.lines[line_index].x == offset);
        try check(prepared.lines[line_index].y == line_y);
    }
    const expected_height = if (expected_lines.len == 0) 0 else @as(i32, @intCast(expected_lines.len)) * font.line_height + @as(i32, @intCast(expected_lines.len - 1)) * options.line_spacing;
    try check(measured.width == logical_width and measured.height == expected_height);
    if (expected_lines.len != 0) try check(source_cursor == text.len);
    try pixelsEqual(&actual, &expected);
    fold(pixel_hash, up.testSupport.canvasHash(actual));
    foldMetrics(metric_hash, &prepared);
}

fn verify(allocator: std.mem.Allocator) !Report {
    var fixture = Fixture{};
    var font = fixture.font(allocator);
    var pixel_hash = std.hash.Fnv1a_64.init();
    var metric_hash = std.hash.Fnv1a_64.init();
    var count: u32 = 0;
    const Case = struct { text: []const u8, lines: []const []const u8, options: Font.TextOptions = .{} };
    const cases = [_]Case{
        .{ .text = "", .lines = &.{} },
        .{ .text = "\r", .lines = &.{} },
        .{ .text = "\n", .lines = &.{ "", "" } },
        .{ .text = "W\n", .lines = &.{ "W", "" } },
        .{ .text = "W\r\ni", .lines = &.{ "W\r", "i" } },
        .{ .text = "WWW", .lines = &.{"WWW"} },
        .{ .text = "iii", .lines = &.{"iii"} },
        .{ .text = "Wi", .lines = &.{"Wi"} },
        .{ .text = "É你\tW", .lines = &.{"É你\tW"} },
        .{ .text = &invalid, .lines = &.{&invalid} },
        .{ .text = "W ii", .lines = &.{ "W ", "ii" }, .options = .{ .max_width = 8 } },
        .{ .text = "W ii", .lines = &.{ "W i", "i" }, .options = .{ .max_width = 8, .wrap = .glyph } },
        .{ .text = "i Wiii", .lines = &.{ "i ", "Wi", "ii" }, .options = .{ .max_width = 8 } },
        .{ .text = "WW", .lines = &.{ "W", "W" }, .options = .{ .max_width = 3 } },
        .{ .text = "  i ", .lines = &.{ "  ", "i", " " }, .options = .{ .max_width = 2 } },
        .{ .text = "WW", .lines = &.{"WW"}, .options = .{ .max_width = 3, .wrap = .none } },
        .{ .text = "zW", .lines = &.{"zW"} },
        .{ .text = "W\n\nÉi\n", .lines = &.{ "W", "", "Éi", "" }, .options = .{ .line_spacing = 3 } },
    };
    for (cases) |case| {
        for ([_]up.graphics.TextAlignment{ .left, .center, .right }) |alignment| {
            var options = case.options;
            options.alignment = alignment;
            failed_case = count;
            try pixelCase(allocator, &font, case.text, options, case.lines, count, &pixel_hash, &metric_hash);
            count += 1;
        }
    }
    const bearings = try font.measureText("Wi", .{});
    try check(bearings.width == 7 and bearings.height == 7);
    try check(std.meta.eql(bearings.bounds.?, Font.TextMetrics.Bounds{ .x = -1, .y = 0, .width = 7, .height = 3 }));
    const accent = try font.measureText("É", .{});
    try check(accent.bounds.?.x == -1 and accent.bounds.?.y == -1);
    font.fallback_codepoint = null;
    try pixelCase(allocator, &font, "W你i", .{}, &.{"W你i"}, count, &pixel_hash, &metric_hash);
    count += 1;
    font.fallback_codepoint = '?';
    // Deterministic malformed/Unicode/missing-glyph unwrapped differential cases.
    var rng: u32 = 0xfeedcafe;
    const chunks = [_][]const u8{ "W", "i", " ", "\t", "É", "你", "\xc0\x80", "\xff", "z" };
    for (0..256) |_| {
        var bytes: [128]u8 = undefined;
        var len: usize = 0;
        for (0..19) |_| {
            rng = rng *% 1664525 +% 1013904223;
            const chunk = chunks[(rng >> 16) % chunks.len];
            @memcpy(bytes[len..][0..chunk.len], chunk);
            len += chunk.len;
        }
        failed_case = count;
        try pixelCase(allocator, &font, bytes[0..len], .{ .max_width = 49, .wrap = .none, .alignment = if (count % 2 == 0) .center else .right }, &.{bytes[0..len]}, count, &pixel_hash, &metric_hash);
        count += 1;
    }
    var sans = try Font.decodeTrueType(allocator, source_sans, .{});
    defer sans.deinit();
    var mono = try Font.decodeTrueType(allocator, basic, .{ .pixel_height = 12, .atlas_width = 128, .atlas_height = 128, .first_codepoint = 32, .codepoint_count = 96 });
    defer mono.deinit();
    for ([_]*const Font{ &sans, &mono }) |authored| {
        for ([_][]const u8{ "WWW", "iii", "É café 你好", &invalid, "W \tiii" }) |text| {
            failed_case = count;
            try pixelCase(allocator, authored, text, .{}, &.{text}, count, &pixel_hash, &metric_hash);
            count += 1;
        }
        // Actual proportional/bitmap metrics, with known word boundaries.
        const width = 3 * authored.resolveGlyph('W').glyph.?.advance + authored.resolveGlyph(' ').glyph.?.advance;
        for ([_]up.graphics.TextAlignment{ .left, .center, .right }) |alignment| {
            failed_case = count;
            try pixelCase(allocator, authored, "WWW iii", .{ .max_width = width, .alignment = alignment, .line_spacing = 2 }, &.{ "WWW ", "iii" }, count, &pixel_hash, &metric_hash);
            count += 1;
        }
    }
    failed_case = count;
    try limits(allocator);
    failed_case = count + 1;
    try inputOwnership(allocator);
    failed_case = count + 2;
    fold(&pixel_hash, try menuScenario(allocator));
    var old = try up.graphics.layoutText(allocator, "WWW", .{});
    defer old.deinit();
    return .{ .cases = count, .pixel_hash = pixel_hash.final(), .metrics_hash = metric_hash.final(), .legacy_www = old.width, .authored_www = (try sans.measureText("WWW", .{})).width, .authored_iii = (try sans.measureText("iii", .{})).width };
}

test "authored layouts match hand measurements and unchanged Font.drawText pixels" {
    report = verify(std.testing.allocator) catch |err| {
        std.debug.print("font layout case={d} pixel={d}: {s}\n", .{ failed_case, failed_pixel, @errorName(err) });
        return err;
    };
    try std.testing.expect(report.authored_www != report.authored_iii);
    try std.testing.expectEqual(@as(i32, 12), report.legacy_www);
}

fn allocationScenario(allocator: std.mem.Allocator) !void {
    var fixture = Fixture{};
    const font = fixture.font(allocator);
    var prepared = try font.layoutText(allocator, "W iW É iii", .{ .max_width = 8 });
    defer prepared.deinit();
}

fn menuScenario(allocator: std.mem.Allocator) !u64 {
    var counter = Counter{ .parent = allocator };
    const runner = try up.testSupport.HeadlessGameRunner(menu.Game).init(counter.allocator(), menu.width, menu.height);
    defer runner.deinit();
    // The ordinary host has no trace. Opt-in headless trace capture can grow
    // its own observer buffers; it is separate from prepared text drawing.
    runner.canvas.detachTrace();
    try runner.draw(0);
    const initial = runner.capture().image_hash;
    var input = up.input.Input{};
    input.set(.down, true);
    input.set(.action, true);
    try runner.step(input.snapshot(), 1.0 / 60.0);
    try check(runner.game.selected == 1 and runner.game.page == 1);
    counter.operations = 0;
    try runner.draw(0);
    try check(counter.operations == 0);
    try check(runner.capture().image_hash != initial);
    return runner.capture().image_hash;
}

fn menuAllocationScenario(allocator: std.mem.Allocator) !void {
    const runner = try up.testSupport.HeadlessGameRunner(menu.Game).init(allocator, menu.width, menu.height);
    defer runner.deinit();
}

test "prepared layout releases partial arrays on every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationScenario, .{});
}

test "menu releases prepared layouts and font on every failed initialization" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, menuAllocationScenario, .{});
}

pub export fn font_layout_run() u32 {
    report = verify(std.heap.page_allocator) catch return 1;
    return 0;
}
pub export fn font_layout_cases() u32 {
    return report.cases;
}
pub export fn font_layout_pixels() u64 {
    return report.pixel_hash;
}
pub export fn font_layout_metrics() u64 {
    return report.metrics_hash;
}
pub export fn font_layout_failure_case() u32 {
    return failed_case;
}
pub export fn font_layout_failure_pixel() u32 {
    return failed_pixel;
}
pub fn main() !void {
    if (comptime builtin.os.tag == .freestanding) return;
    report = try verify(std.heap.page_allocator);
    var bytes: [256]u8 = undefined;
    try std.fs.File.stdout().writeAll(try std.fmt.bufPrint(
        &bytes,
        "{{\"cases\":{d},\"pixel_hash\":\"{d}\",\"metrics_hash\":\"{d}\",\"legacy_www\":{d},\"authored_www\":{d},\"authored_iii\":{d}}}\n",
        .{ report.cases, report.pixel_hash, report.metrics_hash, report.legacy_www, report.authored_www, report.authored_iii },
    ));
}
