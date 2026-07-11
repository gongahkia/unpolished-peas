const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const engine_root = args.next() orelse return usage();
    const template_root = args.next() orelse return usage();
    const destination = args.next() orelse return usage();
    if (args.next() != null) return usage();

    try createProject(allocator, engine_root, template_root, destination);
    std.debug.print("created unpolished-peas project: {s}\n", .{destination});
}

fn createProject(allocator: std.mem.Allocator, engine_root: []const u8, template_root: []const u8, destination: []const u8) !void {
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
    try source.copyFile("src/main.zig", output, "src/main.zig", .{});

    const manifest = try std.fmt.allocPrint(allocator,
        \\.{{
        \\    .name = .unpolished_peas_game,
        \\    .version = "0.0.1",
        \\    .fingerprint = 0x68a23f24006f3ea5, // Changing this has security and trust implications.
        \\    .minimum_zig_version = "0.15.2",
        \\    .dependencies = .{{
        \\        .unpolished_peas = .{{ .path = "{s}" }},
        \\    }},
        \\    .paths = .{{
        \\        "build.zig",
        \\        "build.zig.zon",
        \\        "src",
        \\        "README.md",
        \\    }},
        \\}}
        \\ 
    , .{engine_root});
    defer allocator.free(manifest);
    try output.writeFile(.{ .sub_path = "build.zig.zon", .data = manifest });
}

fn usage() error{InvalidArguments} {
    std.debug.print("usage: zig build new -- <directory>\n", .{});
    return error.InvalidArguments;
}
