const std = @import("std");
const up = @import("unpolished-peas");
const sdl = @import("unpolished-peas-sdl3");

const actions = [_]up.Action{
    .{ .name = "left", .binding = .{ .key = .left } },
    .{ .name = "right", .binding = .{ .key = .right } },
    .{ .name = "up", .binding = .{ .key = .up } },
    .{ .name = "down", .binding = .{ .key = .down } },
};

const Game = struct {
    pub const config: sdl.Config = .{
        .title = "external tile-map camera actions",
        .organization = "fixture",
        .application = "external-tilemap-camera-actions",
        .width = 96,
        .height = 64,
        .scale = 4,
        .fixed_hz = 60,
        .max_frames = 2,
        .actions = &actions,
        .clear_color = up.Color.rgb(12, 18, 28),
    };

    map: up.TileMap,
    player: up.Vec2 = .{ .x = 24, .y = 20 },
    camera: up.Camera2D = .{ .position = .{ .x = 24, .y = 20 } },

    pub fn init(ctx: *sdl.Context) !Game {
        var map = try up.TileMap.init(ctx.allocator, .{ .x = 8, .y = 8 }, 8);
        errdefer map.deinit();
        const terrain = try map.addLayer("terrain", .tiles, null);
        _ = try map.addTileSet("debug", .grid_image, "user-owned", .{ .x = 8, .y = 8 });
        var x: i32 = 0;
        while (x < 12) : (x += 1) try map.setTile(terrain, .{ .x = x, .y = 6 }, .{ .tileset = 0, .id = 0 });
        return .{ .map = map };
    }

    pub fn deinit(self: *Game, _: *sdl.Context) void {
        self.map.deinit();
    }

    pub fn update(self: *Game, ctx: *sdl.Context) void {
        self.advance(ctx.actions.*, ctx.input.*, ctx.dt, .{ .x = @floatFromInt(ctx.canvas.width), .y = @floatFromInt(ctx.canvas.height) });
    }

    pub fn draw(self: *Game, ctx: *sdl.Context) void {
        self.map.drawDebug(ctx.camera(&self.camera));
        ctx.camera(&self.camera).fillCircle(self.player, 4, up.Color.rgb(255, 198, 74));
        ctx.text("ARROWS MOVE", 3, 3, up.Color.white);
    }

    fn advance(self: *Game, bindings: up.ActionMap, input: up.Input, dt: f32, canvas_size: up.Vec2) void {
        const direction = up.Vec2{
            .x = bindings.value(input, "game", "right") - bindings.value(input, "game", "left"),
            .y = bindings.value(input, "game", "down") - bindings.value(input, "game", "up"),
        };
        self.player = self.player.add(direction.scale(48 * dt));
        self.camera.setFollowTarget(self.player);
        self.camera.update(dt, canvas_size);
    }
};

fn replaceAfterMtime(dir: std.fs.Dir, path: []const u8, bytes: []const u8) !void {
    const previous = try dir.statFile(path);
    while (true) {
        try dir.writeFile(.{ .sub_path = path, .data = bytes });
        if ((try dir.statFile(path)).mtime != previous.mtime) return;
        std.Thread.sleep(1_000_000_000);
    }
}

pub fn main() !void {
    try sdl.playGame(Game);
}

test "external tile-map game moves through configured actions and follows with its camera" {
    var game = Game{ .map = try up.TileMap.init(std.testing.allocator, .{ .x = 8, .y = 8 }, 8) };
    defer game.map.deinit();
    const bindings = up.ActionMap{ .actions = &actions };
    var input = up.Input{};
    input.set(.right, true);
    game.advance(bindings, input, 0.5, .{ .x = 96, .y = 64 });
    try std.testing.expectEqual(@as(f32, 48), game.player.x);
    try std.testing.expect(game.camera.position.x > 24);
}

test "external tile-map game reloads a user-owned shader" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const shader_source = try std.fs.cwd().readFileAlloc(std.testing.allocator, "assets/pulse.upshader", 64 * 1024);
    defer std.testing.allocator.free(shader_source);
    try tmp.dir.writeFile(.{ .sub_path = "pulse.upshader", .data = shader_source });
    var store = up.AssetStore.init(std.testing.allocator, tmp.dir);
    defer store.deinit();
    const pulse = try store.loadShader("pulse.upshader");
    try replaceAfterMtime(tmp.dir, "pulse.upshader", "effect=passthrough\n");
    const reloads = try store.reloadChanged();
    try std.testing.expectEqual(@as(usize, 1), reloads.len);
    try std.testing.expectEqualStrings("pulse.upshader", reloads[0].path);
    try std.testing.expectEqual(up.ReloadStatus.changed, reloads[0].status);
    try std.testing.expectError(error.StaleHandle, store.tryShaderSource(pulse));
}
