const up = @import("unpolished-peas");
const sdl = @import("unpolished-peas-sdl3");
const physics = @import("unpolished-peas-physics");
const platformer = @import("platformer_game.zig");

const Game = struct {
    game: platformer.Game,
    map: up.TileMapHandle,
    collider: up.TileCollider,
    atlas: up.AtlasHandle,
    animation: up.AnimationPlayer,
    world: physics.World,
    marker: physics.BodyHandle,
    jump_sound: up.AudioHandle,
    ui: up.UiState = .{},

    pub fn init(ctx: *sdl.Context) !Game {
        const map = try ctx.loadTileMap("platformer.upmap");
        var collider = up.TileCollider.init(ctx.allocator);
        errdefer collider.deinit();
        try collider.addLayer(ctx.tileMap(map), 0);
        const atlas = try ctx.loadAtlas("atlas.json");
        const animation = ctx.atlasAnimation(atlas, "pulse").?;
        var world = physics.World.init(.{ .gravity = .{ .x = 0, .y = 4 } });
        errdefer world.deinit();
        const marker = try world.createBody(.{ .body_type = .dynamic, .position = .{ .x = 84, .y = 8 } });
        _ = try world.createCircle(marker, .{ .radius = 2 });
        return .{ .game = try .init(.{ .x = 8, .y = 0 }), .map = map, .collider = collider, .atlas = atlas, .animation = up.AnimationPlayer.init(ctx.atlas(atlas), animation), .world = world, .marker = marker, .jump_sound = try ctx.assets.loadSound("blip.wav") };
    }
    pub fn deinit(self: *Game, _: *sdl.Context) void {
        self.collider.deinit();
        self.world.deinit();
    }
    pub fn update(self: *Game, ctx: *sdl.Context) !void {
        const jump = ctx.input.wasPressed(.action);
        _ = self.game.step(&self.collider, .{ .left = ctx.down(.left), .right = ctx.down(.right), .jump = jump }, ctx.dt);
        if (jump) _ = try ctx.audio.playSound(try ctx.assets.trySoundPtr(self.jump_sound), .{});
        self.animation.update(ctx.dt);
        try self.world.step(ctx.dt, 4);
        if (ctx.down(.action)) try ctx.setPixelEffect("invert", .{ .amount = 0.2 }) else ctx.clearPixelEffect();
    }
    pub fn draw(self: *Game, ctx: *sdl.Context) !void {
        const camera = up.Camera2D{ .position = .{ .x = 48, .y = 24 } };
        ctx.drawTileMap(self.map, &camera, 0);
        ctx.sprite(self.atlas, self.animation.frame(), @intFromFloat(self.game.controller.bounds.x), @intFromFloat(self.game.controller.bounds.y), .{ .scale = 2 });
        try self.world.appendDebug(ctx.commands, &camera, .{ .x = @floatFromInt(ctx.canvas.width), .y = @floatFromInt(ctx.canvas.height) });
        const marker = self.world.bodyPosition(self.marker) catch return;
        ctx.gpuCamera(&camera).fillCircle(marker, 2, up.Color.rgb(255, 198, 74));
        var ui = up.UiFrame.begin(&self.ui, ctx.input, .{ .hud = ctx.canvas }, .{ .cursor = .{ .x = 104, .y = 2 }, .width = 50, .row_height = 10 });
        _ = ui.button(1, "DEBUG");
        ui.end();
        ctx.text("PLATFORMER", 2, 2, up.Color.white);
    }
};

pub fn main() !void {
    try sdl.play(.{ .title = "unpolished-peas Platformer", .width = 160, .height = 64, .scale = 5, .fixed_hz = 60, .clear_color = up.Color.rgb(12, 18, 28) }, Game);
}
