//! Crisp authored world and prepared UI; drawing never changes simulation.
const std = @import("std");
const up = @import("unpolished-peas");
const game = @import("game.zig");
const level = @import("level.zig");
const Color = up.core.Color;
const ink = Color.rgb(225, 233, 248);
const muted = Color.rgb(149, 171, 198);
const gold = Color.rgb(255, 216, 116);
fn panel(c: *up.graphics.Canvas, y: i32, h: i32) void {
    c.fillRect(18, y, 284, h, Color.rgba(7, 13, 29, 245));
    c.strokeRect(18, y, 284, h, Color.rgb(75, 103, 132));
    c.fillRect(20, y + 2, 2, h - 4, gold);
}
pub fn draw(self: *game.Game, ctx: *up.core.GameContext) !void {
    const c = try ctx.requireCanvas();
    const surface = if (self.surface) |*value| value else return error.GameNotInitialized;
    const atlas = self.atlas orelse return error.GameNotInitialized;
    const font = self.font orelse return error.GameNotInitialized;
    const world = surface.canvas();
    world.clear(Color.rgb(13, 23, 45));
    var camera = up.graphics.Camera2D{ .position = .{ .x = self.camera_x, .y = 45 }, .pixel_snap = .nearest };
    const view = up.graphics.CameraCanvas.init(world, &camera);
    // Quiet structure keeps the collision surfaces and warm lights foremost.
    for (0..16) |index| {
        const x = @as(f32, @floatFromInt(index)) * 27;
        view.fillRect(.init(x, 28, 11, 54), Color.rgb(19, 32, 54));
        view.line(.{ .x = x + 5, .y = 12 }, .{ .x = x + 5, .y = 74 }, Color.rgb(24, 40, 61));
    }
    for (level.platforms) |platform| {
        view.fillRect(platform, Color.rgb(54, 72, 101));
        view.line(.{ .x = platform.x, .y = platform.y }, .{ .x = platform.x + platform.w - 1, .y = platform.y }, Color.rgb(150, 184, 189));
        view.line(.{ .x = platform.x, .y = platform.y + 2 }, .{ .x = platform.x + platform.w - 1, .y = platform.y + 2 }, Color.rgb(81, 107, 132));
    }
    for (level.hazards) |hazard| {
        var x = hazard.x;
        while (x < hazard.x + hazard.w) : (x += 8) view.drawAtlasFrame(atlas.*, .{ .index = 7 }, .{ .x = x, .y = hazard.y - 4 }, .{});
        view.line(.{ .x = hazard.x, .y = 82 }, .{ .x = hazard.x + hazard.w, .y = 82 }, Color.rgb(255, 115, 143));
    }
    for (level.collectible_positions, 0..) |position, index| if (!self.collected[index]) {
        view.drawAtlasFrame(atlas.*, .{ .index = 4 }, position, .{ .origin = .center });
        view.line(.{ .x = position.x - 2, .y = position.y + 6 }, .{ .x = position.x + 2, .y = position.y + 6 }, gold);
    };
    for (level.checkpoint_bounds, 0..) |bounds, index| {
        const active = self.checkpoint == index + 1;
        view.drawAtlasFrame(atlas.*, .{ .index = 5 }, .{ .x = bounds.x + 1, .y = bounds.y + 2 }, .{ .tint = if (active) gold else muted });
        if (active) view.line(.{ .x = bounds.x - 1, .y = bounds.y + 12 }, .{ .x = bounds.x + 11, .y = bounds.y + 12 }, gold);
    }
    view.line(.{ .x = 351, .y = 20 }, .{ .x = 351, .y = 51 }, Color.rgb(91, 100, 84));
    view.drawAtlasFrame(atlas.*, .{ .index = 6 }, .{ .x = level.goal_bounds.x + 1, .y = level.goal_bounds.y + 5 }, .{});
    const animation = self.player_animation orelse return error.GameNotInitialized;
    view.drawAtlasFrame(atlas.*, animation.currentFrame(), self.player.position, .{ .flip_x = self.player.facing_left, .tint = if (self.dead) Color.rgb(255, 152, 169) else Color.white });
    c.clear(Color.rgb(6, 12, 24));
    try c.drawSurface(surface, .{ .x = 0, .y = 20, .width = 320, .height = 160, .filter = .nearest });
    c.fillRect(0, 0, 320, 20, Color.rgb(10, 18, 33));
    c.fillRect(0, 180, 320, 20, Color.rgb(10, 18, 33));
    c.line(0, 19, 319, 19, Color.rgb(54, 78, 102));
    self.text.draw(c, .glows, 8, 3, muted);
    self.text.draw(c, .best, 107, 3, muted);
    var buffer: [40]u8 = undefined;
    font.drawText(c, try std.fmt.bufPrint(&buffer, "{d}/6", .{self.collectedCount()}), 55, 3, gold);
    font.drawText(c, try std.fmt.bufPrint(&buffer, "{d}/6", .{self.best_collectibles}), 142, 3, ink);
    self.text.draw(c, if (self.audio_enabled) .audio_on else .audio_off, 204, 3, muted);
    const footer: @import("ui.zig").Label = if (self.save_failed) .pending else if (self.notice_ticks > 0) switch (self.notice) {
        .glow => .pickup,
        .checkpoint => .checkpoint,
        .queued => .buffer,
        .unavailable => .unavailable,
        .back => .back,
        .bonk => .low_ceiling,
        .none => .footer,
    } else .footer;
    self.text.draw(c, footer, 8, 183, if (self.save_failed) Color.rgb(255, 156, 139) else if (self.notice_ticks > 0) gold else muted);
    if (!self.save_failed) self.text.draw(c, .pause_key, 244, 183, muted);
    if (self.screen == .title) {
        panel(c, 35, 128);
        self.text.centered(c, .title, 44, gold);
        self.text.centered(c, .subtitle, 60, muted);
        self.text.centered(c, .objective, 78, ink);
        self.text.centered(c, .move, 98, ink);
        self.text.centered(c, .jump, 114, ink);
        if (self.completion_unlocked) self.text.centered(c, .record_lit, 128, muted);
        self.text.centered(c, if (self.run_started and !self.completed) .continue_run else if (self.completed) .replay else .begin, 141, gold);
        if (self.load_problem) self.text.centered(c, .load_warning, 166, Color.rgb(255, 156, 139));
    } else if (self.screen == .paused) {
        panel(c, 45, 104);
        self.text.centered(c, .paused, 56, gold);
        self.text.centered(c, .resume_play, 80, ink);
        self.text.centered(c, .restart, 101, ink);
        self.text.centered(c, if (self.save_failed) .pending else .saved, 125, if (self.save_failed) Color.rgb(255, 156, 139) else muted);
    } else if (self.dead) {
        panel(c, 64, 67);
        self.text.centered(c, .dark, 73, Color.rgb(255, 156, 139));
        self.text.centered(c, .respawn, 98, ink);
    } else if (self.completed) {
        panel(c, 53, 89);
        self.text.centered(c, .complete, 63, gold);
        if (self.collectedCount() == 6) self.text.centered(c, .all_glows, 84, ink);
        self.text.centered(c, .replay, 117, ink);
    }
}
