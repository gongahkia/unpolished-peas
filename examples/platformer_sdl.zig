const up = @import("unpolished-peas");
const sdl = @import("unpolished-peas-sdl3");
const platformer = @import("platformer_game.zig");
const content = @import("programmatic_content.zig");

const Game = struct {
    pub const config: sdl.Config = .{ .title = "unpolished-peas Platformer", .width = 160, .height = 64, .scale = 5, .fixed_hz = 60, .clear_color = up.Color.rgb(12, 18, 28) };

    game: platformer.Game,
    map: up.TileMap,
    collider: up.TileCollider,
    atlas: *up.Atlas,
    animation: up.AnimationPlayer,
    tile_image: up.ImageHandle,
    jump_sound: up.AudioHandle,

    pub fn init(ctx: *sdl.Context) !Game {
        const generated_map = try content.platformerMap(ctx.allocator);
        var map = generated_map.map;
        errdefer map.deinit();
        var collider = up.TileCollider.init(ctx.allocator);
        errdefer collider.deinit();
        try collider.addLayer(&map, generated_map.collision_layer);
        const tile_image = try ctx.loadImage("ball.png");
        const image = try ctx.assets.tryImage(tile_image);
        const atlas = try ctx.allocator.create(up.Atlas);
        errdefer ctx.allocator.destroy(atlas);
        atlas.* = try content.ballAtlas(ctx.allocator, image);
        errdefer {
            atlas.deinit();
            ctx.allocator.destroy(atlas);
        }
        const animation = atlas.findAnimation("pulse") orelse return error.MissingAtlasAnimation;
        return .{ .game = try .init(.{ .x = 8, .y = 0 }), .map = map, .collider = collider, .atlas = atlas, .animation = up.AnimationPlayer.init(atlas, animation), .tile_image = tile_image, .jump_sound = try ctx.loadSound("blip.wav") };
    }
    pub fn deinit(self: *Game, _: *sdl.Context) void {
        self.collider.deinit();
        self.map.deinit();
        const allocator = self.atlas.allocator;
        self.atlas.deinit();
        allocator.destroy(self.atlas);
    }
    pub fn update(self: *Game, ctx: *sdl.Context) !void {
        const jump = ctx.input.wasPressed(.action);
        _ = self.game.step(&self.collider, .{ .left = ctx.down(.left), .right = ctx.down(.right), .jump = jump }, ctx.dt);
        if (jump) _ = try ctx.audio.playSound(try ctx.assets.trySoundPtr(self.jump_sound), .{});
        self.animation.update(ctx.dt);
    }
    pub fn draw(self: *Game, ctx: *sdl.Context) !void {
        const camera = up.Camera2D{ .position = .{ .x = 48, .y = 24 } };
        const images = [_]up.Image{try ctx.assets.tryImage(self.tile_image)};
        self.map.drawImages(ctx.camera(&camera), &images);
        try ctx.spriteAtlas(self.atlas, self.animation.frame(), @intFromFloat(self.game.controller.bounds.x), @intFromFloat(self.game.controller.bounds.y), .{ .scale = 2 });
        ctx.text("PLATFORMER", 2, 2, up.Color.white);
    }
};

pub fn main() !void {
    try sdl.playGame(Game);
}
