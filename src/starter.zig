const std = @import("std");
const tools = @import("unpolished-peas-tools");

const release_tag = "v0.0.4";
const release_url = "https://github.com/gongahkia/unpolished-peas/archive/refs/tags/" ++ release_tag ++ ".tar.gz";

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

    try createProject(allocator, template_root, destination);
    std.debug.print("created unpolished-peas project: {s}\n", .{destination});
}

pub fn createProject(allocator: std.mem.Allocator, template_root: []const u8, destination: []const u8) !void {
    const dependency_hash = try resolveReleaseHash(allocator);
    defer allocator.free(dependency_hash);
    try createProjectWithDependencyHash(allocator, template_root, destination, dependency_hash);
}

fn createProjectWithDependencyHash(allocator: std.mem.Allocator, template_root: []const u8, destination: []const u8, dependency_hash: []const u8) !void {
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
    try source.copyFile("README.md", output, "README.md", .{});
    try source.copyFile(".gitignore", output, ".gitignore", .{});
    try output.makePath("assets");
    try source.copyFile("assets/.gitkeep", output, "assets/.gitkeep", .{});
    try source.copyFile("src/main.zig", output, "src/main.zig", .{});

    const manifest = try std.fmt.allocPrint(allocator,
        \\.{{
        \\    .name = .unpolished_peas_game,
        \\    .version = "0.0.1",
        \\    .fingerprint = 0x68a23f24006f3ea5, // Changing this has security and trust implications.
        \\    .minimum_zig_version = "0.15.2",
        \\    .dependencies = .{{
        \\        .unpolished_peas = .{{
        \\            .url = "{s}",
        \\            .hash = "{s}",
        \\        }},
        \\    }},
        \\    .paths = .{{
        \\        "build.zig",
        \\        "build.zig.zon",
        \\        "src",
        \\        "assets",
        \\        "README.md",
        \\    }},
        \\}}
        \\ 
    , .{ release_url, dependency_hash });
    defer allocator.free(manifest);
    try output.writeFile(.{ .sub_path = "build.zig.zon", .data = manifest });
}

fn resolveReleaseHash(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "UP_STARTER_DEPENDENCY_HASH") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    }) |override| {
        if (!std.mem.startsWith(u8, override, "unpolished_peas-")) {
            allocator.free(override);
            return error.InvalidDependencyHash;
        }
        return override;
    }

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "zig", "fetch", release_url },
        .max_output_bytes = 4096,
    });
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);
    switch (result.term) {
        .Exited => |code| if (code != 0) return error.DependencyFetchFailed,
        else => return error.DependencyFetchFailed,
    }
    const hash = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (!std.mem.startsWith(u8, hash, "unpolished_peas-")) return error.InvalidDependencyHash;
    return allocator.dupe(u8, hash);
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

    try createProjectWithDependencyHash(std.testing.allocator, template_root, destination, "unpolished_peas-0.0.4-test");
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
    try std.testing.expect(std.mem.indexOf(u8, source, "sdl.playGame(Game)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "unpolished-peas").? < std.mem.indexOf(u8, source, "up.core.Color").?);
    const manifest = try project.readFileAlloc(std.testing.allocator, "build.zig.zon", 4096);
    defer std.testing.allocator.free(manifest);
    try std.testing.expect(std.mem.indexOf(u8, manifest, release_url) != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "unpolished_peas-0.0.4-test") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"assets\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"maps\"") == null);
    const check_issue = try tools.checkProject(std.testing.allocator, destination);
    try std.testing.expect(check_issue == null);
    try std.testing.expectError(error.DestinationExists, createProjectWithDependencyHash(std.testing.allocator, template_root, destination, "unpolished_peas-0.0.4-test"));
    try std.testing.expectError(error.InvalidDestination, createProjectWithDependencyHash(std.testing.allocator, template_root, "", "unpolished_peas-0.0.4-test"));
}
