const std = @import("std");
const up = @import("unpolished-peas");
const sdl = @import("unpolished-peas-sdl3");

const max_file_bytes = 64 * 1024 * 1024;

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
    const scene_source = try readPackageFile(allocator, package, "content/scenes/main.upscene");
    defer allocator.free(scene_source);
    const catalog_source = try readPackageFile(allocator, package, "content/assets/catalog.upassets");
    defer allocator.free(catalog_source);
    const map_source = try readPackageFile(allocator, package, "content/maps/main.upmap");
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

    try validateCache(allocator, package, "content/cache/scenes/main.upscene.upc", .scene);
    try validateCache(allocator, package, "content/cache/assets/catalog.upassets.upc", .catalog);
    try validateCache(allocator, package, "content/cache/maps/main.upmap.upc", .map);
    try probeAppData(allocator, package);
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

fn probeAppData(allocator: std.mem.Allocator, package: []const u8) !void {
    const app_data = try sdl.appDataPath(allocator, "unpolished-peas", "package-layout-smoke");
    defer allocator.free(app_data);
    if (std.mem.startsWith(u8, app_data, package)) return error.AppDataInsidePackage;
    try std.fs.cwd().makePath(app_data);
    const probe = try std.fs.path.join(allocator, &.{ app_data, "write-probe" });
    defer allocator.free(probe);
    defer std.fs.cwd().deleteFile(probe) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = probe, .data = "ok" });
}
