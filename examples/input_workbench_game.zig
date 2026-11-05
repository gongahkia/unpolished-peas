const std = @import("std");
const up = @import("unpolished-peas");

pub const width: u32 = 320;
pub const height: u32 = 180;
const definitions = [_]up.input.Action{
    .{ .name = "left", .binding = .{ .physical_key = .q } },
    .{ .name = "right", .binding = .{ .physical_key = .e } },
    .{ .name = "one", .binding = .{ .physical_key = .digit_1 } },
    .{ .name = "two", .binding = .{ .physical_key = .digit_2 } },
};

/// Portable game state: the desktop wrapper and browser runtime use this same
/// type. Input/rebinding happen only in fixed updates. No SDL or DOM imports.
pub const Game = struct {
    actions: ?up.input.ActionMap = null,
    font: ?up.assets.Font = null,
    x: i32 = 150,
    one: u32 = 0,
    two: u32 = 0,
    rebound: bool = false,
    editing: bool = false,
    composing: bool = false,
    overflow: bool = false,
    name: [64]u8 = .{0} ** 64,
    name_len: usize = 0,
    preedit: [1024]u8 = .{0} ** 1024,
    preedit_len: usize = 0,

    pub fn init(self: *Game, ctx: *up.core.GameContext) !void {
        const allocator = try ctx.requireAllocator();
        self.actions = try up.input.ActionMap.init(allocator, &definitions);
        errdefer self.actions.?.deinit();
        self.font = try up.assets.Font.decodeTrueType(allocator, @embedFile("assets/fonts/SourceSans3-Regular.otf"), .{ .pixel_height = 14 });
    }

    pub fn deinit(self: *Game, _: *up.core.GameContext) !void {
        if (self.font) |*font| font.deinit();
        if (self.actions) |*actions| actions.deinit();
    }

    pub fn update(self: *Game, ctx: *up.core.GameContext, _: f32) !void {
        for (ctx.input.extended.eventSlice()) |event| {
            switch (event.kind) {
                .key_down => {
                    const key = event.key.?;
                    if (key == .f4 and !event.repeat) {
                        self.editing = !self.editing;
                        try ctx.setTextInput(self.editing);
                    } else if (key == .f5 and !event.repeat) {
                        self.rebound = !self.rebound;
                        try self.actions.?.rebind("game", "left", .{ .physical_key = if (self.rebound) .r else .q });
                    } else if (self.editing and key == .backspace and !self.composing and self.name_len > 0) {
                        // Code-point deletion; this example is not a grapheme editor.
                        self.name_len -= 1;
                        while (self.name_len > 0 and self.name[self.name_len] & 0xc0 == 0x80) self.name_len -= 1;
                    } else if (self.editing and (key == .escape or key == .enter) and !self.composing) {
                        self.editing = false;
                        try ctx.setTextInput(false);
                    }
                },
                .text_commit => if (self.editing) {
                    const text = ctx.input.extended.eventText(event);
                    if (text.len <= self.name.len - self.name_len) {
                        @memcpy(self.name[self.name_len..][0..text.len], text);
                        self.name_len += text.len;
                    } else self.overflow = true;
                },
                .composition_start => self.composing = true,
                .composition_update => {
                    const text = ctx.input.extended.eventText(event);
                    @memcpy(self.preedit[0..text.len], text);
                    self.preedit_len = text.len;
                },
                .composition_end, .composition_cancel, .text_stopped => {
                    self.composing = false;
                    self.preedit_len = 0;
                },
                else => {},
            }
        }
        if (ctx.input.extended.overflow) {
            self.overflow = true;
            self.editing = false;
            self.composing = false;
            self.preedit_len = 0;
            try ctx.setTextInput(false);
        }
        self.actions.?.update(ctx.input.*);
        if (!self.editing) {
            if (self.actions.?.isDown("game", "left")) self.x -= 1;
            if (self.actions.?.isDown("game", "right")) self.x += 1;
            if (self.actions.?.wasPressed("game", "one")) self.one +%= 1;
            if (self.actions.?.wasPressed("game", "two")) self.two +%= 1;
            self.x = std.math.clamp(self.x, 0, 310);
        }
    }

    pub fn draw(self: *Game, ctx: *up.core.GameContext) !void {
        const canvas = try ctx.requireCanvas();
        canvas.clear(up.core.Color.rgb(15, 22, 30));
        const font = &self.font.?;
        const color = up.core.Color.white;
        font.drawText(canvas, "Q/E move   1/2 count   F5 rebind Q/R", 8, 8, color);
        font.drawText(canvas, "F4 name entry   Enter finish   Esc cancel preedit", 8, 25, color);
        canvas.fillRect(self.x, 55, 10, 10, up.core.Color.rgb(90, 210, 160));
        var buffer: [96]u8 = undefined;
        const counts = try std.fmt.bufPrint(&buffer, "1: {d}   2: {d}   Left: {s}", .{ self.one, self.two, if (self.rebound) "R" else "Q" });
        font.drawText(canvas, counts, 8, 75, color);
        font.drawText(canvas, if (self.editing) "Editing name:" else "Name:", 8, 96, color);
        font.drawText(canvas, self.name[0..self.name_len], 8, 113, color);
        font.drawText(canvas, self.preedit[0..self.preedit_len], 8, 132, up.core.Color.rgb(255, 200, 90));
        if (self.preedit_len != 0) canvas.fillRect(8, 147, 280, 1, up.core.Color.rgb(255, 200, 90));
        if (self.overflow) font.drawText(canvas, "Input capacity reached; entry stopped", 8, 158, up.core.Color.rgb(255, 120, 100));
    }
};

test "portable input example reproduces rebinding Unicode name and composition" {
    const allocator = std.testing.allocator;
    var recorder = try up.preview.developer.InputReplayRecorder.initSeeded(allocator, 60, 42);
    defer recorder.deinit();
    var input = up.input.Input{};
    input.setPhysical(.q, true, false);
    input.setPhysical(.digit_1, true, false);
    input.setPhysical(.digit_2, true, false);
    try recorder.record(input);
    input.beginFrame();
    input.releaseAll();
    input.setPhysical(.f5, true, false);
    input.setPhysical(.r, true, false);
    try recorder.record(input);
    input.beginFrame();
    input.releaseAll();
    input.setPhysical(.f4, true, false);
    try recorder.record(input);
    input.beginFrame();
    input.setTextInputActive(true);
    try input.updateComposition("Zoe", 3, 0);
    try recorder.record(input);
    input.beginFrame();
    input.extended.endComposition();
    try input.commitText("Zoë你好");
    try recorder.record(input);
    var replay = try recorder.finish();
    defer replay.deinit(allocator);
    const bytes = try replay.encode(allocator);
    defer allocator.free(bytes);
    var decoded = try up.preview.developer.parseInputReplay(allocator, bytes);
    defer decoded.deinit(allocator);
    var first = try up.testSupport.HeadlessGameRunner(Game).initSeeded(allocator, width, height, 42);
    defer first.deinit();
    var second = try up.testSupport.HeadlessGameRunner(Game).initSeeded(allocator, width, height, 42);
    defer second.deinit();
    try first.runReplay(replay);
    try second.runReplay(decoded);
    try std.testing.expectEqualStrings("Zoë你好", first.game.name[0..first.game.name_len]);
    try std.testing.expectEqual(@as(i32, 148), first.game.x);
    try std.testing.expectEqual(@as(u32, 1), first.game.one);
    try std.testing.expectEqual(@as(u32, 1), first.game.two);
    try std.testing.expect(first.game.rebound);
    try std.testing.expect(!first.game.composing);
    try std.testing.expectEqual(first.capture().image_hash, second.capture().image_hash);
    try up.testSupport.expectCanvasTraceEqual(first.capture().canvas_trace, second.capture().canvas_trace);
}
