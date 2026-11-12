//! Game-owned drawing; simulation advances only in Game.update.
const std = @import("std");
const up = @import("unpolished-peas");
const game = @import("game.zig");
const Game = game.Game;
const width = game.width;
const height = game.height;
const art = @import("art.zig");
pub fn draw(self: *Game, ctx: *up.core.GameContext) !void {
    const canvas = try ctx.requireCanvas();
    const surface = if (self.surface) |*value| value else return error.GameNotInitialized;
    const atlas = self.atlas orelse return error.GameNotInitialized;
    _ = self.font orelse return error.GameNotInitialized;
    const world = surface.canvas();
    world.clear(up.core.Color.rgb(8, 12, 24));

    var camera = up.graphics.Camera2D{ .position = self.player.position, .pixel_snap = .nearest };
    const world_canvas = up.graphics.CameraCanvas.init(world, &camera);
    var grid_x: i32 = 0;
    while (grid_x <= 120) : (grid_x += 10) world_canvas.line(.{ .x = @floatFromInt(grid_x), .y = 0 }, .{ .x = @floatFromInt(grid_x), .y = 70 }, up.core.Color.rgb(18, 31, 55));
    var grid_y: i32 = 0;
    while (grid_y <= 70) : (grid_y += 10) world_canvas.line(.{ .x = 0, .y = @floatFromInt(grid_y) }, .{ .x = 120, .y = @floatFromInt(grid_y) }, up.core.Color.rgb(18, 31, 55));
    world_canvas.strokeRect(.init(0, 0, 120, 70), up.core.Color.rgb(56, 87, 126));
    for (self.pickups) |pickup| if (pickup.active) world_canvas.drawAtlasFrame(atlas.*, self.pickup_frame, pickup.position, .{ .origin = .center });
    for (self.enemies) |enemy| if (enemy.active) world_canvas.drawAtlasFrame(atlas.*, self.enemy_frame, enemy.position, .{ .origin = .center });
    for (self.projectiles) |projectile| if (projectile.active) world_canvas.drawAtlasFrame(atlas.*, self.projectile_frame, projectile.position, .{ .origin = .center });
    const player_animation = self.player_animation orelse return error.GameNotInitialized;
    world_canvas.drawAtlasFrame(atlas.*, player_animation.currentFrame(), self.player.position, .{ .origin = .center });

    canvas.clear(up.core.Color.rgb(3, 5, 13));
    try canvas.drawSurface(surface, .{ .x = 0, .y = 0, .width = width, .height = height, .filter = .nearest });
    canvas.fillRect(0, 0, @intCast(width), 12, up.core.Color.rgba(3, 5, 13, 220));
    canvas.fillRect(0, 74, @intCast(width), 16, up.core.Color.rgba(3, 5, 13, 235));
    // The 5x7 bitmap glyphs stay sharp when this small canvas is scaled up.
    var status: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&status, "SCORE {d} HP {d} WAVE {d}", .{ self.score, self.player.health, self.wave });
    canvas.drawText(text, 3, 2, up.core.Color.rgb(231, 242, 255));
    canvas.drawText("ARROWS MOVE SPACE FIRE", 3, 74, up.core.Color.rgb(173, 197, 222));
    canvas.drawText("X DASH  ENTER RESTART", 3, 82, up.core.Color.rgb(173, 197, 222));
    if (self.game_over) {
        canvas.fillRect(10, 31, 140, 26, up.core.Color.rgba(7, 9, 19, 230));
        canvas.drawText("SYSTEM BREACH", 41, 36, up.core.Color.rgb(255, 120, 151));
        canvas.drawText("PRESS ENTER TO RESTART", 14, 46, up.core.Color.rgb(235, 241, 250));
    }
}
