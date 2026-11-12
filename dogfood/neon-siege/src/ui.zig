//! Immutable prepared copy borrows the game's stable authored font.
const std = @import("std");
const up = @import("unpolished-peas");
pub const Label = enum { title, subtitle, move, aim, fire, sprint, begin, pause_key, restart, paused, resume_play, new_run, audio_on, audio_off, score, best, wave, hull, breach, footer, sprint_key, heal, pickup, hit, incoming, pending, load_warning };
pub const copy = [_][]const u8{ "NEON SIEGE", "HOLD THE LINE. KEEP MOVING.", "ARROWS / WASD / LEFT STICK: MOVE", "IJKL / RIGHT STICK: AIM", "SPACE / SOUTH / RB: FIRE", "HOLD X / EAST: SPRINT, NOT A SHIELD", "ENTER / START: BEGIN", "ESC / START: PAUSE", "ENTER / START: TRY AGAIN", "CIRCUIT PAUSED", "ENTER / ESC / START: RESUME", "R / LEFT SHOULDER: NEW RUN", "M / BACK: AUDIO ON", "M / BACK: AUDIO OFF", "SCORE", "BEST", "WAVE", "HULL", "SYSTEM BREACH", "ARROWS MOVE  SPACE FIRE", "X SPRINT", "REPAIR +1", "ENERGY +5", "HIT -1: RECOVERING", "WAVE INCOMING", "SAVE PENDING - RESUME TO RETRY", "SETTINGS UNREADABLE - PLAY IS AVAILABLE" };
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
