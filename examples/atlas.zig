const up = @import("unpolished-peas");
const sdl = @import("unpolished-peas-sdl3");
const content = @import("programmatic_content.zig");

const Game = struct {
    pub const config: sdl.Config = .{
        .title = "unpolished-peas atlas",
        .width = 128,
        .height = 72,
        .scale = 5,
        .clear_color = up.Color.rgb(14, 18, 24),
    };

    atlas: *up.Atlas,
    tiles: [4]up.AtlasFrameHandle,
    player: up.AnimationPlayer,

    pub fn init(ctx: *sdl.Context) !Game {
        const atlas = try ctx.allocator.create(up.Atlas);
        errdefer ctx.allocator.destroy(atlas);
        atlas.* = try content.ballAtlas(ctx.allocator, try ctx.assets.tryImage(try ctx.loadImage("ball.png")));
        errdefer atlas.deinit();
        const animation = atlas.findAnimation("pulse") orelse return error.MissingAtlasAnimation;
        return .{
            .atlas = atlas,
            .tiles = .{
                atlas.findFrame("tile_a") orelse return error.MissingAtlasFrame,
                atlas.findFrame("tile_b") orelse return error.MissingAtlasFrame,
                atlas.findFrame("tile_c") orelse return error.MissingAtlasFrame,
                atlas.findFrame("tile_d") orelse return error.MissingAtlasFrame,
            },
            .player = up.AnimationPlayer.init(atlas, animation),
        };
    }

    pub fn deinit(self: *Game, _: *sdl.Context) void {
        const allocator = self.atlas.allocator;
        self.atlas.deinit();
        allocator.destroy(self.atlas);
    }

    pub fn update(self: *Game, ctx: *sdl.Context) void {
        self.player.update(ctx.dt);
    }

    pub fn draw(self: *Game, ctx: *sdl.Context) !void {
        const map = [_]u8{
            0, 1, 0, 1, 2, 3, 2, 3,
            2, 3, 2, 3, 0, 1, 0, 1,
            0, 1, 2, 3, 0, 1, 2, 3,
            2, 3, 0, 1, 2, 3, 0, 1,
        };
        for (map, 0..) |tile, i| {
            const x: i32 = @intCast((i % 8) * 8);
            const y: i32 = @intCast((i / 8) * 8);
            try ctx.spriteAtlas(self.atlas, self.tiles[tile], x, y, .{});
        }
        try ctx.spriteAtlas(self.atlas, self.player.frame(), 104, 36, .{ .origin = .center, .scale = 3, .flip_x = true, .tint = up.Color.rgb(220, 240, 255), .rotation = 0.2, .sampling = .linear });
        ctx.text("ATLAS", 72, 8, up.Color.white);
    }
};

pub fn main() !void {
    try sdl.playGame(Game);
}
