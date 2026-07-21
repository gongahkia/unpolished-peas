const std = @import("std");
const tools = @import("unpolished-peas-tools");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const template_root = args.next() orelse return usage();
    const destination = args.next() orelse return usage();
    if (args.next() != null) return usage();

    try createProject(template_root, destination);
    std.debug.print("created unpolished-peas project: {s}\n", .{destination});
}

pub fn createProject(template_root: []const u8, destination: []const u8) !void {
    try validateDestination(destination);
    if (std.fs.cwd().access(destination, .{})) |_| return error.DestinationExists else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    var source = try std.fs.openDirAbsolute(template_root, .{});
    defer source.close();
    var output = try std.fs.cwd().makeOpenPath(destination, .{});
    defer output.close();
    try output.makePath("src");
    try source.copyFile("build.zig", output, "build.zig", .{});
    try source.copyFile("build.zig.zon", output, "build.zig.zon", .{});
    try source.copyFile("README.md", output, "README.md", .{});
    try source.copyFile(".gitignore", output, ".gitignore", .{});
    try output.makePath("assets");
    try source.copyFile("assets/.gitkeep", output, "assets/.gitkeep", .{});
    try source.copyFile("src/main.zig", output, "src/main.zig", .{});
}

pub fn validateDestination(destination: []const u8) !void {
    const name = std.fs.path.basename(destination);
    if (destination.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidDestination;
}

fn usage() error{InvalidArguments} {
    std.debug.print("usage: zig build new -- <directory>\n", .{});
    return error.InvalidArguments;
}

test "starter creates a structured project and rejects invalid destinations" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const destination = try std.fs.path.join(std.testing.allocator, &.{ root, "game" });
    defer std.testing.allocator.free(destination);
    const template_root = try std.fs.cwd().realpathAlloc(std.testing.allocator, "templates/bounce");
    defer std.testing.allocator.free(template_root);

    try createProject(template_root, destination);
    var project = try std.fs.openDirAbsolute(destination, .{});
    defer project.close();
    try project.access("build.zig", .{});
    try project.access("build.zig.zon", .{});
    try project.access("src/main.zig", .{});
    try project.access("assets/.gitkeep", .{});
    const source = try project.readFileAlloc(std.testing.allocator, "src/main.zig", 8192);
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "const up = @import(\"unpolished-peas\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "up.core.Color") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "up.core.Vec2") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "*up.core.GameContext") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "*sdl.Context") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "sdl.playGame(Game)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "unpolished-peas").? < std.mem.indexOf(u8, source, "up.core.Color").?);
    const manifest = try project.readFileAlloc(std.testing.allocator, "build.zig.zon", 4096);
    defer std.testing.allocator.free(manifest);
    const template_manifest = try std.fs.cwd().readFileAlloc(std.testing.allocator, "templates/bounce/build.zig.zon", 4096);
    defer std.testing.allocator.free(template_manifest);
    try std.testing.expectEqualStrings(template_manifest, manifest);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"assets\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"maps\"") == null);
    const check_issue = try tools.checkProject(std.testing.allocator, destination);
    try std.testing.expect(check_issue == null);
    try std.testing.expectError(error.DestinationExists, createProject(template_root, destination));
    try std.testing.expectError(error.InvalidDestination, createProject(template_root, ""));
}
