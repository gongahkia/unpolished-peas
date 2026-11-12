//! Game-owned drawing; simulation advances only in Game.update.
const std = @import("std");
const up = @import("unpolished-peas");
const game = @import("game.zig");
const Game = game.Game;
const width = game.width;
const height = game.height;
const player_width = game.player_width;
const art = @import("art.zig");
const level = @import("level.zig");
pub fn draw(self: *Game, ctx: *up.core.GameContext) !void {
    const canvas = try ctx.requireCanvas();
    const surface = if (self.surface) |*value| value else return error.GameNotInitialized;
    const atlas = self.atlas orelse return error.GameNotInitialized;
    _ = self.font orelse return error.GameNotInitialized;
    const world = surface.canvas();
    world.clear(up.core.Color.rgb(12, 17, 37));

    var camera = up.graphics.Camera2D{
        .position = .{
            .x = std.math.clamp(self.player.position.x + player_width / 2, @as(f32, 80), level.world_width - 80),
            .y = 45,
        },
        .zoom = 0.5,
        .pixel_snap = .nearest,
    };
    const world_canvas = up.graphics.CameraCanvas.init(world, &camera);
    world_canvas.fillRect(.init(0, 0, level.world_width, level.world_height), up.core.Color.rgb(18, 26, 56));
    for (level.platforms) |platform| {
        world_canvas.fillRect(platform, up.core.Color.rgb(83, 91, 137));
        world_canvas.strokeRect(platform, up.core.Color.rgb(145, 160, 211));
    }
    for (level.hazards) |hazard| {
        var spike_x = hazard.x;
        while (spike_x < hazard.x + hazard.w) : (spike_x += 8) {
            world_canvas.drawAtlasFrame(atlas.*, .{ .index = 7 }, .{ .x = spike_x, .y = hazard.y - 4 }, .{});
        }
    }
    for (level.collectible_positions, 0..) |position, index| if (!self.collected[index]) {
        world_canvas.drawAtlasFrame(atlas.*, .{ .index = 4 }, position, .{ .origin = .center });
    };
    for (level.checkpoint_bounds, 0..) |bounds, index| {
        const active = self.checkpoint == index + 1;
        world_canvas.drawAtlasFrame(atlas.*, .{ .index = 5 }, .{ .x = bounds.x + 1, .y = bounds.y + 2 }, .{ .tint = if (active) up.core.Color.rgb(255, 241, 150) else up.core.Color.rgb(170, 170, 190) });
    }
    world_canvas.drawAtlasFrame(atlas.*, .{ .index = 6 }, .{ .x = level.goal_bounds.x + 1, .y = level.goal_bounds.y + 5 }, .{});
    const animation = self.player_animation orelse return error.GameNotInitialized;
    world_canvas.drawAtlasFrame(atlas.*, animation.currentFrame(), self.player.position, .{ .flip_x = self.player.facing_left });

    canvas.clear(up.core.Color.rgb(4, 7, 18));
    try canvas.drawSurface(surface, .{ .x = 0, .y = 0, .width = width, .height = height, .filter = .nearest });
    canvas.fillRect(0, 0, @intCast(width), 11, up.core.Color.rgba(4, 7, 18, 225));
    canvas.fillRect(0, 79, @intCast(width), 11, up.core.Color.rgba(4, 7, 18, 235));
    // The 5x7 bitmap glyphs stay sharp when this small canvas is scaled up.
    var hud: [48]u8 = undefined;
    const text = try std.fmt.bufPrint(&hud, "GLOWS {d}/{d}  BEST {d}", .{ self.collectedCount(), level.collectible_positions.len, self.best_collectibles });
    canvas.drawText(text, 3, 2, up.core.Color.rgb(235, 244, 255));
    canvas.drawText("ARROWS MOVE SPACE JUMP", 3, 81, up.core.Color.rgb(201, 214, 245));
    if (self.dead) {
        canvas.fillRect(32, 33, 96, 24, up.core.Color.rgba(5, 8, 20, 230));
        canvas.drawText("LANTERN OUT", 44, 37, up.core.Color.rgb(255, 159, 174));
        canvas.drawText("RESPAWNING", 47, 46, up.core.Color.rgb(229, 237, 255));
    }
    if (self.completed) {
        canvas.fillRect(18, 32, 124, 26, up.core.Color.rgba(5, 8, 20, 235));
        canvas.drawText("THE WAY IS LIT", 38, 37, up.core.Color.rgb(255, 235, 128));
        canvas.drawText("ENTER TO WALK AGAIN", 23, 46, up.core.Color.rgb(229, 237, 255));
    }
}
