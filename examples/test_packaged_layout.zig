const std = @import("std");
const up = @import("unpolished-peas");
const sdl = @import("unpolished-peas-sdl3");

const max_file_bytes = 64 * 1024 * 1024;

const PackageGame = enum {
    bounce,
    topdown,
    platformer,
};

const Launcher = struct {
    game: []const u8,
};

const ContentFixture = struct {
    scene: []const u8,
    catalog: []const u8,
    map: []const u8,
    scene_cache: []const u8,
    catalog_cache: []const u8,
    map_cache: []const u8,
};

pub fn main() !void {
    verify() catch |err| {
        std.debug.print("package verification failed: {s}; recovery: restore a checksum-verified package archive\n", .{@errorName(err)});
        return err;
    };
}

fn verify() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const executable_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(executable_path);
    const bin = std.fs.path.dirname(executable_path) orelse return error.InvalidPackageLayout;
    const package = std.fs.path.dirname(bin) orelse return error.InvalidPackageLayout;
    const game = try packageGame(allocator, package);
    const fixture = contentFixture(game);

    var assets = try up.AssetStore.initExecutable(allocator);
    defer assets.deinit();
    _ = try assets.loadImage("ball.png");
    _ = try assets.loadAtlas("atlas.json");
    _ = try assets.loadTileMap("topdown.tmj");
    _ = try assets.loadFont("fonts/Basic-Regular.ttf");
    _ = try assets.loadBitmapFont("fonts/bitmap.fnt");
    const wav_path = try assets.assetPath(allocator, "blip.wav");
    defer allocator.free(wav_path);
    var sound = try up.Sound.loadWav(allocator, wav_path);
    defer sound.deinit();
    const ogg_path = try assets.assetPath(allocator, "tone.ogg");
    defer allocator.free(ogg_path);
    var music = try up.Music.openOgg(allocator, ogg_path);
    defer music.deinit();

    const project = try readPackageFile(allocator, package, "content/project.up");
    defer allocator.free(project);
    const scene_source = try readPackageFile(allocator, package, fixture.scene);
    defer allocator.free(scene_source);
    const catalog_source = try readPackageFile(allocator, package, fixture.catalog);
    defer allocator.free(catalog_source);
    const map_source = try readPackageFile(allocator, package, fixture.map);
    defer allocator.free(map_source);

    var scene_diagnostic: up.SceneDiagnostic = .{};
    var scene = try up.scene.parse(allocator, scene_source, &scene_diagnostic);
    defer scene.deinit(allocator);
    var catalog_diagnostic: up.AssetCatalogDiagnostic = .{};
    var catalog = try up.assetCatalog.parse(allocator, catalog_source, &catalog_diagnostic);
    defer catalog.deinit(allocator);
    var map_diagnostic: up.MapSourceDiagnostic = .{};
    var map = try up.mapSource.parse(allocator, map_source, &map_diagnostic);
    defer map.deinit(allocator);

    try validateCache(allocator, package, fixture.scene_cache, .scene);
    try validateCache(allocator, package, fixture.catalog_cache, .catalog);
    try validateCache(allocator, package, fixture.map_cache, .map);
    try probeAppData(allocator, package, game);
}

fn packageGame(allocator: std.mem.Allocator, package: []const u8) !PackageGame {
    const launcher_source = try readPackageFile(allocator, package, "launcher.json");
    defer allocator.free(launcher_source);
    var launcher = try std.json.parseFromSlice(Launcher, allocator, launcher_source, .{ .ignore_unknown_fields = true });
    defer launcher.deinit();
    return std.meta.stringToEnum(PackageGame, launcher.value.game) orelse error.InvalidPackageGame;
}

fn contentFixture(game: PackageGame) ContentFixture {
    return switch (game) {
        .bounce, .topdown => .{
            .scene = "content/scenes/topdown.upscene",
            .catalog = "content/assets/topdown.upassets",
            .map = "content/maps/topdown.upmap",
            .scene_cache = "content/cache/scenes/topdown.upscene.upc",
            .catalog_cache = "content/cache/assets/topdown.upassets.upc",
            .map_cache = "content/cache/maps/topdown.upmap.upc",
        },
        .platformer => .{
            .scene = "content/scenes/platformer.upscene",
            .catalog = "content/assets/platformer.upassets",
            .map = "content/maps/platformer.upmap",
            .scene_cache = "content/cache/scenes/platformer.upscene.upc",
            .catalog_cache = "content/cache/assets/platformer.upassets.upc",
            .map_cache = "content/cache/maps/platformer.upmap.upc",
        },
    };
}

fn readPackageFile(allocator: std.mem.Allocator, package: []const u8, relative_path: []const u8) ![]u8 {
    const path = try std.fs.path.join(allocator, &.{ package, relative_path });
    defer allocator.free(path);
    return std.fs.cwd().readFileAlloc(allocator, path, max_file_bytes);
}

fn validateCache(allocator: std.mem.Allocator, package: []const u8, relative_path: []const u8, expected_kind: up.contentCache.Kind) !void {
    const source = try readPackageFile(allocator, package, relative_path);
    defer allocator.free(source);
    var decoded = try up.contentCache.decode(allocator, source);
    defer decoded.deinit();
    if (decoded.kind != expected_kind) return error.InvalidPackageCache;
}

fn probeAppData(allocator: std.mem.Allocator, package: []const u8, game: PackageGame) !void {
    const app_name = switch (game) {
        .bounce => "bounce-package-smoke",
        .topdown => "topdown-package-smoke",
        .platformer => "platformer-package-smoke",
    };
    const app_data = try sdl.appDataPath(allocator, "unpolished-peas", app_name);
    defer allocator.free(app_data);
    if (std.mem.startsWith(u8, app_data, package)) return error.AppDataInsidePackage;
    try std.fs.cwd().makePath(app_data);
    const probe = try std.fs.path.join(allocator, &.{ app_data, "write-probe" });
    defer allocator.free(probe);
    defer std.fs.cwd().deleteFile(probe) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = probe, .data = "ok" });
}
