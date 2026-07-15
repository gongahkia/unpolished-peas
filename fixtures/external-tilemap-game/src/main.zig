const std = @import("std");
const up = @import("unpolished-peas").api;
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

    map: ?up.TileMapHandle = null,
    catalog: ?up.assetCatalog.Loaded = null,
    player: up.Vec2 = .{ .x = 24, .y = 20 },
    camera: up.Camera2D = .{ .position = .{ .x = 24, .y = 20 } },

    pub fn init(ctx: *sdl.Context) !Game {
        var catalog = try loadCatalog(ctx.allocator, ctx.assets);
        errdefer catalog.deinit();
        return .{ .map = try ctx.loadTileMap("world.upmap", .{}), .catalog = catalog };
    }

    pub fn deinit(self: *Game, _: *sdl.Context) void {
        if (self.catalog) |*catalog| catalog.deinit();
    }

    pub fn update(self: *Game, ctx: *sdl.Context) void {
        self.advance(ctx.actions.*, ctx.input.*, ctx.dt, .{ .x = @floatFromInt(ctx.canvas.width), .y = @floatFromInt(ctx.canvas.height) });
    }

    pub fn draw(self: *Game, ctx: *sdl.Context) !void {
        if (self.map) |map| try ctx.drawTileMap(map, &self.camera, 0);
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

fn loadCatalog(allocator: std.mem.Allocator, store: *up.AssetStore) !up.assetCatalog.Loaded {
    const bytes = try store.dir.readFileAlloc(allocator, "world.upassets", 64 * 1024);
    defer allocator.free(bytes);
    var diagnostic = up.assetCatalog.Diagnostic{};
    var source = try up.assetCatalog.parse(allocator, bytes, &diagnostic);
    defer source.deinit(allocator);
    return up.assetCatalog.load(allocator, store, source);
}

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
    var game = Game{};
    const bindings = up.ActionMap{ .actions = &actions };
    var input = up.Input{};
    input.set(.right, true);
    game.advance(bindings, input, 0.5, .{ .x = 96, .y = 64 });
    try std.testing.expectEqual(@as(f32, 48), game.player.x);
    try std.testing.expect(game.camera.position.x > 24);
}

test "external tile-map game loads native assets and map then reloads its catalog asset" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const catalog_source = try std.fs.cwd().readFileAlloc(std.testing.allocator, "assets/world.upassets", 64 * 1024);
    defer std.testing.allocator.free(catalog_source);
    const map_source = try std.fs.cwd().readFileAlloc(std.testing.allocator, "assets/world.upmap", 64 * 1024);
    defer std.testing.allocator.free(map_source);
    const shader_source = try std.fs.cwd().readFileAlloc(std.testing.allocator, "assets/pulse.upshader", 64 * 1024);
    defer std.testing.allocator.free(shader_source);
    try tmp.dir.writeFile(.{ .sub_path = "world.upassets", .data = catalog_source });
    try tmp.dir.writeFile(.{ .sub_path = "world.upmap", .data = map_source });
    try tmp.dir.writeFile(.{ .sub_path = "pulse.upshader", .data = shader_source });
    var store = up.AssetStore.init(std.testing.allocator, tmp.dir);
    defer store.deinit();
    var catalog = try loadCatalog(std.testing.allocator, &store);
    defer catalog.deinit();
    const map = try store.loadTileMap("world.upmap", .{});
    try std.testing.expectEqual(@as(usize, 1), (try store.tryTileMap(map)).layers.items.len);
    const pulse = catalog.handle("pulse") orelse return error.MissingPulse;
    try replaceAfterMtime(tmp.dir, "pulse.upshader", "effect=passthrough\n");
    const reloads = try catalog.reloadChanged(&store);
    try std.testing.expectEqual(@as(usize, 1), reloads.len);
    try std.testing.expectEqualStrings("pulse", reloads[0].id);
    try std.testing.expectEqual(up.ReloadStatus.changed, reloads[0].event.status);
    switch (pulse) {
        .shader => |handle| try std.testing.expectError(error.StaleHandle, store.tryShader(handle)),
        else => unreachable,
    }
    try replaceAfterMtime(tmp.dir, "world.upmap", map_source);
    const map_reloads = try store.reloadChanged();
    try std.testing.expectEqual(@as(usize, 1), map_reloads.len);
    try std.testing.expectEqualStrings("world.upmap", map_reloads[0].path);
    try std.testing.expectEqual(up.ReloadStatus.changed, map_reloads[0].status);
    try std.testing.expectError(error.StaleHandle, store.tryTileMap(map));
}
