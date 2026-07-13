const std = @import("std");

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

fn createProject(allocator: std.mem.Allocator, template_root: []const u8, destination: []const u8) !void {
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
        \\            .url = "https://github.com/gongahkia/unpolished-peas/archive/refs/tags/v0.0.3.tar.gz",
        \\            .hash = "unpolished_peas-0.0.3-NgUp2fkUGwBwIM0m4MCAABnpI0Cf3baA7TFc_SJ71n1S",
        \\        }},
        \\    }},
        \\    .paths = .{{
        \\        "build.zig",
        \\        "build.zig.zon",
        \\        "src",
        \\        "README.md",
        \\    }},
        \\}}
        \\ 
    , .{});
    defer allocator.free(manifest);
    try output.writeFile(.{ .sub_path = "build.zig.zon", .data = manifest });
}

fn usage() error{InvalidArguments} {
    std.debug.print("usage: zig build new -- <directory>\n", .{});
    return error.InvalidArguments;
}
