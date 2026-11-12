//! Immutable prepared copy borrows the game's stable authored font.
const std = @import("std");
const up = @import("unpolished-peas");
pub const Label = enum { title, subtitle, objective, move, jump, restart, begin, continue_run, replay, paused, resume_play, dark, respawn, complete, all_glows, glows, best, audio_on, audio_off, footer, pause_key, checkpoint, pickup, buffer, unavailable, pending, load_warning, saved, back, low_ceiling, record_lit };
pub const copy = [_][]const u8{
    "LANTERN LEAP",                     "A LITTLE LIGHT GOES A LONG WAY",              "Find six glows. Reach the beacon.",
    "ARROWS / WASD / LEFT STICK: MOVE", "SPACE / SOUTH: JUMP. RELEASE FOR A LOW HOP.", "R / LEFT SHOULDER: NEW RUN",
    "ENTER / START: BEGIN",             "ENTER / START: CONTINUE",                     "ENTER / START: WALK AGAIN",
    "TAKE A BREATH",                    "ENTER / ESC / START: RESUME",                 "LANTERN OUT",
    "ENTER / START: RESPAWN NOW",       "THE WAY IS LIT",                              "ALL SIX GLOWS FOUND",
    "GLOWS",                            "BEST",                                        "M / BACK: AUDIO ON",
    "M / BACK: AUDIO OFF",              "MOVE: ARROWS   JUMP: SPACE",                  "ESC: PAUSE",
    "CHECKPOINT LIT",                   "GLOW FOUND",                                  "JUMP QUEUED",
    "LAND TO JUMP",                     "SAVE PENDING - RESUME TO RETRY",              "SAVE UNREADABLE - PLAY IS AVAILABLE",
    "PROGRESS SAVED",                   "BACK AT YOUR LANTERN",                        "LOW CEILING - STEP CLEAR",
    "BEACON RECORD: LIT",
};
pub const Text = struct {
    layouts: [copy.len]?up.assets.Font.TextLayout = .{null} ** copy.len,
    pub fn init(self: *Text, allocator: std.mem.Allocator, font: *const up.assets.Font) !void {
        errdefer self.deinit();
        for (copy, &self.layouts) |text, *layout| layout.* = try font.layoutText(allocator, text, .{ .wrap = .none });
    }
    pub fn deinit(self: *Text) void {
        for (&self.layouts) |*layout| {
            if (layout.*) |*value| value.deinit();
            layout.* = null;
        }
    }
    pub fn draw(self: *const Text, c: *up.graphics.Canvas, label: Label, x: i32, y: i32, color: up.core.Color) void {
        if (self.layouts[@intFromEnum(label)]) |layout| layout.draw(c, x, y, color);
    }
    pub fn centered(self: *const Text, c: *up.graphics.Canvas, label: Label, y: i32, color: up.core.Color) void {
        const layout = self.layouts[@intFromEnum(label)] orelse return;
        layout.draw(c, @divTrunc(320 - layout.metrics.width, 2), y, color);
    }
};
