const up = @import("unpolished-peas");
const sdl = @import("unpolished-peas-sdl3");

const Game = struct {
    atlas: up.AtlasHandle,
    tiles: [4]up.AtlasFrameHandle,
    player: up.AnimationPlayer,

    pub fn init(ctx: *sdl.Context) !Game {
        const atlas = try ctx.loadAtlas("atlas.json");
        const animation = ctx.atlasAnimation(atlas, "pulse").?;
        return .{
            .atlas = atlas,
            .tiles = .{
                ctx.atlasFrame(atlas, "tile_a").?,
                ctx.atlasFrame(atlas, "tile_b").?,
                ctx.atlasFrame(atlas, "tile_c").?,
                ctx.atlasFrame(atlas, "tile_d").?,
            },
            .player = up.AnimationPlayer.init(ctx.atlas(atlas), animation),
        };
    }

    pub fn update(self: *Game, ctx: *sdl.Context) void {
        self.player.update(ctx.dt);
    }

    pub fn draw(self: *Game, ctx: *sdl.Context) void {
        const map = [_]u8{
            0, 1, 0, 1, 2, 3, 2, 3,
            2, 3, 2, 3, 0, 1, 0, 1,
            0, 1, 2, 3, 0, 1, 2, 3,
            2, 3, 0, 1, 2, 3, 0, 1,
        };
        for (map, 0..) |tile, i| {
            const x: i32 = @intCast((i % 8) * 8);
            const y: i32 = @intCast((i / 8) * 8);
            ctx.sprite(self.atlas, self.tiles[tile], x, y, .{});
        }
        ctx.sprite(self.atlas, self.player.frame(), 104, 36, .{ .origin = .center, .scale = 3, .flip_x = true, .tint = up.Color.rgb(220, 240, 255), .rotation = 0.2, .sampling = .linear });
        ctx.text("ATLAS", 72, 8, up.Color.white);
    }
};

pub fn main() !void {
    try sdl.play(.{
        .title = "unpolished-peas atlas",
        .width = 128,
        .height = 72,
        .scale = 5,
        .clear_color = up.Color.rgb(14, 18, 24),
    }, Game);
}
