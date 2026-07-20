const std = @import("std");
const up = @import("unpolished-peas");
const sdl = @import("unpolished-peas-sdl3");

const PackageGame = enum { bounce, topdown, puzzle };
const Launcher = struct { game: []const u8 };

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

    var assets = try up.assets.AssetStore.initExecutable(allocator);
    defer assets.deinit();
    const image_handle = try assets.loadImage("ball.png");
    const image = try assets.tryImage(image_handle);
    if (image.width == 0 or image.height == 0) return error.InvalidRawImage;
    _ = try assets.loadFont("fonts/Basic-Regular.ttf", .{});
    _ = try assets.loadFont("fonts/bitmap.fnt", .{});
    const sound_handle = try assets.loadSound("blip.wav");
    const sound = try assets.trySound(sound_handle);
    if (sound.frames.len == 0) return error.InvalidRawAudio;
    try rejectNativeContent(allocator, package);
    try probeAppData(allocator, package, game);
}

fn packageGame(allocator: std.mem.Allocator, package: []const u8) !PackageGame {
    const source = try readPackageFile(allocator, package, "launcher.json");
    defer allocator.free(source);
    var launcher = try std.json.parseFromSlice(Launcher, allocator, source, .{ .ignore_unknown_fields = true });
    defer launcher.deinit();
    return std.meta.stringToEnum(PackageGame, launcher.value.game) orelse error.InvalidPackageGame;
}

fn readPackageFile(allocator: std.mem.Allocator, package: []const u8, relative_path: []const u8) ![]u8 {
    const path = try std.fs.path.join(allocator, &.{ package, relative_path });
    defer allocator.free(path);
    return std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024);
}

fn rejectNativeContent(allocator: std.mem.Allocator, package: []const u8) !void {
    const content = try std.fs.path.join(allocator, &.{ package, "content" });
    defer allocator.free(content);
    std.fs.cwd().access(content, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    return error.NativeContentShipped;
}

fn probeAppData(allocator: std.mem.Allocator, package: []const u8, game: PackageGame) !void {
    const app_name = switch (game) {
        .bounce => "bounce-package-smoke",
        .topdown => "topdown-package-smoke",
        .puzzle => "puzzle-package-smoke",
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
