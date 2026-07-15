const up = @import("unpolished-peas").api;
const sdl = @import("unpolished-peas-sdl3");

const Game = struct {
    pub const config: sdl.Config = .{
        .title = "unpolished-peas tile map",
        .width = 160,
        .height = 90,
        .scale = 6,
        .resizable = true,
        .clear_color = up.Color.rgb(12, 17, 24),
    };

    map: up.TileMap,
    image: up.ImageHandle,
    camera: up.Camera2D = .{ .position = .{ .x = 80, .y = 45 }, .zoom = 1.5, .bounds = .{ .rect = .init(-128, -128, 512, 384) } },

    pub fn init(ctx: *sdl.Context) !Game {
        var map = try up.TileMap.init(ctx.allocator, .{ .x = 8, .y = 8 }, 16);
        errdefer map.deinit();
        const ball_path = try ctx.assetPath("ball.png");
        defer ctx.allocator.free(ball_path);
        _ = try map.addTileSet("debug", .grid_image, ball_path, .{ .x = 8, .y = 8 });
        const terrain = try map.addLayer("terrain", .tiles, null);
        const detail = try map.addLayer("detail", .tiles, null);
        var y: i32 = -16;
        while (y < 48) : (y += 1) {
            var x: i32 = -16;
            while (x < 64) : (x += 1) {
                if (@rem(x * 17 + y * 11, 5) != 0) try map.setTile(terrain, .{ .x = x, .y = y }, .{ .tileset = 0, .id = @intCast(@mod(x + y, 4)) });
                if (@rem(x + y, 13) == 0) try map.setTile(detail, .{ .x = x, .y = y }, .{ .tileset = 0, .id = 7 });
            }
        }
        return .{ .map = map, .image = try ctx.loadPng("ball.png") };
    }

    pub fn deinit(self: *Game, _: *sdl.Context) void {
        self.map.deinit();
    }

    pub fn update(self: *Game, ctx: *sdl.Context) void {
        var movement = up.Vec2{};
        if (ctx.down(.left)) movement.x -= 72;
        if (ctx.down(.right)) movement.x += 72;
        if (ctx.down(.up)) movement.y -= 72;
        if (ctx.down(.down)) movement.y += 72;
        self.camera.position = self.camera.position.add(movement.scale(ctx.dt));
        if (ctx.input.pointer.canvas) |point| {
            const cell = self.map.worldToCell(self.camera.canvasToWorld(point, .{ .x = @floatFromInt(ctx.canvas.width), .y = @floatFromInt(ctx.canvas.height) }));
            if (ctx.input.pointerWasPressed(.left)) self.map.setTile(0, cell, .{ .tileset = 0, .id = 9 }) catch {};
            if (ctx.input.pointerWasPressed(.right)) self.map.setTile(0, cell, null) catch {};
        }
        self.camera.update(ctx.dt, .{ .x = @floatFromInt(ctx.canvas.width), .y = @floatFromInt(ctx.canvas.height) });
    }

    pub fn draw(self: *Game, ctx: *sdl.Context) void {
        const images = [_]up.Image{ctx.assets.image(self.image)};
        self.map.drawImages(ctx.camera(&self.camera), &images);
        ctx.text("TILE MAP", 4, 4, up.Color.white);
        ctx.text("ARROWS MOVE", 4, 14, up.Color.rgb(170, 198, 225));
        ctx.text("L/R PAINT", 4, 24, up.Color.rgb(170, 198, 225));
    }
};

pub fn main() !void {
    try sdl.playGame(Game);
}
