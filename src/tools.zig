const std = @import("std");

pub const Command = enum {
    new,
    run,
    check,
    @"test",
    package,
};

pub fn parseCommand(value: []const u8) ?Command {
    return std.meta.stringToEnum(Command, value);
}

pub fn printHelp() void {
    std.debug.print(
        \\usage: zig build peas -- <command> [args]
        \\commands: new run check test package
        \\run: zig build peas -- run [project-directory] -- [game-args]
        \\use `zig build peas -- help` for this message
        \\ 
    , .{});
}

pub fn discoverProject(allocator: std.mem.Allocator, start_path: []const u8) ![]u8 {
    var current = try std.fs.cwd().realpathAlloc(allocator, start_path);
    errdefer allocator.free(current);
    while (true) {
        const build_path = try std.fs.path.join(allocator, &.{ current, "build.zig" });
        defer allocator.free(build_path);
        if (std.fs.cwd().access(build_path, .{})) |_| return current else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        const parent = std.fs.path.dirname(current) orelse return error.ProjectNotFound;
        if (std.mem.eql(u8, parent, current)) return error.ProjectNotFound;
        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }
}

pub fn validateProjectAssets(allocator: std.mem.Allocator, root: []const u8) !void {
    const assets_path = try std.fs.path.join(allocator, &.{ root, "assets" });
    defer allocator.free(assets_path);
    std.fs.cwd().access(assets_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.ProjectAssetsMissing,
        else => return err,
    };
}

test "tools module parses CLI commands without runtime imports" {
    try std.testing.expectEqual(Command.new, parseCommand("new").?);
    try std.testing.expect(parseCommand("publish") == null);
}

test "tools discover a project above the selected directory" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.makePath("project/assets");
    try temp.dir.makePath("project/src/nested");
    try temp.dir.writeFile(.{ .sub_path = "project/build.zig", .data = "pub fn build(_: anytype) void {}\n" });
    const root = try temp.dir.realpathAlloc(std.testing.allocator, "project");
    defer std.testing.allocator.free(root);
    const nested = try std.fs.path.join(std.testing.allocator, &.{ root, "src", "nested" });
    defer std.testing.allocator.free(nested);
    const discovered = try discoverProject(std.testing.allocator, nested);
    defer std.testing.allocator.free(discovered);
    try std.testing.expectEqualStrings(root, discovered);
    try validateProjectAssets(std.testing.allocator, discovered);
}

test "tools reject projects without assets" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.makePath("project");
    try temp.dir.writeFile(.{ .sub_path = "project/build.zig", .data = "pub fn build(_: anytype) void {}\n" });
    const root = try temp.dir.realpathAlloc(std.testing.allocator, "project");
    defer std.testing.allocator.free(root);
    try std.testing.expectError(error.ProjectAssetsMissing, validateProjectAssets(std.testing.allocator, root));
}
