//! The complete arena stays visible. All effects observe fixed-update timers.
const std = @import("std");
const up = @import("unpolished-peas");
const game = @import("game.zig");
const Color = up.core.Color;
const ink = Color.rgb(226, 239, 248);
const muted = Color.rgb(137, 169, 191);
const cyan = Color.rgb(105, 235, 241);
const gold = Color.rgb(255, 211, 113);
const pink = Color.rgb(255, 113, 151);
fn panel(c: *up.graphics.Canvas) void {
    c.fillRect(18, 32, 284, 140, Color.rgba(6, 12, 25, 246));
    c.strokeRect(18, 32, 284, 140, Color.rgb(54, 103, 129));
    c.fillRect(20, 34, 2, 136, cyan);
}
pub fn draw(self: *game.Game, ctx: *up.core.GameContext) !void {
    const c = try ctx.requireCanvas();
    const surface = if (self.surface) |*s| s else return error.GameNotInitialized;
    const atlas = self.atlas orelse return error.GameNotInitialized;
    const font = self.font orelse return error.GameNotInitialized;
    const world = surface.canvas();
    world.clear(Color.rgb(8, 17, 31));
    var camera = up.graphics.Camera2D{ .position = .{ .x = 60, .y = 35 }, .pixel_snap = .nearest };
    const view = up.graphics.CameraCanvas.init(world, &camera);
    var x: f32 = 0;
    while (x <= 120) : (x += 10) view.line(.{ .x = x, .y = 0 }, .{ .x = x, .y = 70 }, Color.rgb(16, 35, 52));
    var y: f32 = 0;
    while (y <= 70) : (y += 10) view.line(.{ .x = 0, .y = y }, .{ .x = 120, .y = y }, Color.rgb(16, 35, 52));
    view.strokeRect(.init(0, 0, 120, 70), Color.rgb(55, 107, 134));
    for (self.pickups) |p| if (p.active) {
        view.drawAtlasFrame(atlas.*, self.pickup_frame, p.position, .{ .origin = .center });
        view.strokeRect(.init(p.position.x - 3, p.position.y - 3, 6, 6), gold);
    };
    for (self.enemies) |e| if (e.active) {
        if (e.arming > 0) {
            view.strokeRect(.init(e.position.x - 4, e.position.y - 4, 8, 8), pink);
            view.line(.{ .x = e.position.x - 2, .y = e.position.y }, .{ .x = e.position.x + 2, .y = e.position.y }, pink);
        } else {
            view.drawAtlasFrame(atlas.*, self.enemy_frame, e.position, .{ .origin = .center, .tint = if (e.flash > 0) Color.white else pink });
            if (e.health > 1) view.line(.{ .x = e.position.x - 3, .y = e.position.y - 5 }, .{ .x = e.position.x - 3 + @as(f32, @floatFromInt(e.health)), .y = e.position.y - 5 }, gold);
        }
    };
    for (self.projectiles) |p| if (p.active) view.drawAtlasFrame(atlas.*, self.projectile_frame, p.position, .{ .origin = .center });
    for (self.sparks) |spark| if (spark.ticks > 0) {
        const d: @TypeOf(@as(f32, 0)) = if (spark.ticks > 4) 3 else 2;
        view.line(.{ .x = spark.position.x - d, .y = spark.position.y - d }, .{ .x = spark.position.x + d, .y = spark.position.y + d }, gold);
        view.line(.{ .x = spark.position.x - d, .y = spark.position.y + d }, .{ .x = spark.position.x + d, .y = spark.position.y - d }, gold);
    };
    if (self.sprinting) {
        const behind = self.player.position.sub(self.last_direction.scale(3));
        view.strokeRect(.init(behind.x - 3, behind.y - 3, 6, 6), Color.rgb(43, 117, 142));
    }
    const animation = self.player_animation orelse return error.GameNotInitialized;
    view.drawAtlasFrame(atlas.*, animation.currentFrame(), self.player.position, .{ .origin = .center, .tint = if (self.game_over) pink else Color.white });
    if (self.hurt_ticks > 0) view.strokeRect(.init(self.player.position.x - 5, self.player.position.y - 5, 10, 10), cyan);
    const aim = self.player.position.add(self.last_direction.scale(if (self.muzzle_ticks > 0) 9 else 7));
    view.line(self.player.position.add(self.last_direction.scale(5)), aim, if (self.muzzle_ticks > 0) gold else cyan);
    c.clear(Color.rgb(5, 11, 23));
    try c.drawSurface(surface, .{ .x = 40, .y = 32, .width = 240, .height = 140, .filter = .nearest });
    c.fillRect(0, 0, 320, 28, Color.rgb(9, 20, 35));
    c.line(0, 27, 319, 27, Color.rgb(38, 69, 91));
    self.text.draw(c, .score, 8, 0, muted);
    self.text.draw(c, .best, 119, 0, muted);
    self.text.draw(c, .wave, 237, 0, muted);
    var buffer: [32]u8 = undefined;
    font.drawText(c, try std.fmt.bufPrint(&buffer, "{d}", .{self.score}), 8, 13, ink);
    font.drawText(c, try std.fmt.bufPrint(&buffer, "{d}", .{self.best_score}), 119, 13, gold);
    const wave = if (self.wave > 9999) "9999+" else try std.fmt.bufPrint(&buffer, "{d}", .{self.wave});
    font.drawText(c, wave, 237, 13, cyan);
    if (self.save_failed) self.text.draw(c, .pending, 8, 174, pink) else {
        self.text.draw(c, .hull, 8, 174, muted);
        for (0..3) |index| c.fillRect(43 + @as(i32, @intCast(index)) * 10, 178, 7, 5, if (index < self.player.health) cyan else Color.rgb(45, 63, 81));
        if (self.notice_ticks > 0 and self.screen == .playing and !self.game_over) self.text.draw(c, switch (self.notice) {
            .hit => .hit,
            .heal => .heal,
            .pickup => .pickup,
            .wave => .incoming,
            .none => .footer,
        }, 92, 174, if (self.notice == .hit) pink else gold);
        self.text.draw(c, .pause_key, 212, 174, muted);
    }
    self.text.draw(c, .footer, 8, 187, muted);
    self.text.draw(c, .sprint_key, 150, 187, if (self.sprinting) cyan else muted);
    self.text.draw(c, if (self.audio_enabled) .audio_on else .audio_off, 204, 187, muted);
    if (self.screen == .title) {
        panel(c);
        self.text.centered(c, .title, 41, cyan);
        self.text.centered(c, .subtitle, 58, muted);
        self.text.centered(c, .move, 79, ink);
        self.text.centered(c, .aim, 95, ink);
        self.text.centered(c, .fire, 111, ink);
        self.text.centered(c, .sprint, 127, ink);
        self.text.centered(c, .begin, 151, gold);
        if (self.load_problem) self.text.centered(c, .load_warning, 174, pink);
    } else if (self.game_over) {
        panel(c);
        self.text.centered(c, .breach, 62, pink);
        self.text.centered(c, .subtitle, 85, muted);
        self.text.centered(c, .restart, 126, gold);
    } else if (self.screen == .paused) {
        panel(c);
        self.text.centered(c, .paused, 42, cyan);
        self.text.centered(c, .aim, 65, ink);
        self.text.centered(c, .fire, 81, ink);
        self.text.centered(c, .sprint, 97, ink);
        self.text.centered(c, .new_run, 120, muted);
        self.text.centered(c, .resume_play, 149, gold);
    }
}
