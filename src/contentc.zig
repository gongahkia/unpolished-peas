const std = @import("std");
const content = @import("unpolished-peas-content");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var args = try std.process.argsWithAllocator(gpa.allocator());
    defer args.deinit();
    _ = args.next();
    const project_path = args.next() orelse return usage();
    const output_argument = args.next();
    if (args.next() != null) return usage();
    const project_root = try std.fs.cwd().realpathAlloc(gpa.allocator(), project_path);
    defer gpa.allocator().free(project_root);
    const output_root = if (output_argument) |value|
        try absolutePath(gpa.allocator(), value)
    else
        try std.fs.path.join(gpa.allocator(), &.{ project_root, "zig-out", "content" });
    defer gpa.allocator().free(output_root);
    var diagnostic = content.Diagnostic{};
    defer diagnostic.deinit(gpa.allocator());
    const report = content.compileProject(gpa.allocator(), project_root, output_root, &diagnostic) catch |err| {
        if (diagnostic.path) |path| std.debug.print("{s}:{d}:{d}: {s}\n", .{ path, diagnostic.line, diagnostic.column, diagnostic.message });
        return err;
    };
    std.debug.print("contentc: compiled {d}, reused {d}, output {s}\n", .{ report.compiled, report.reused, output_root });
}

fn absolutePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, path });
}

fn usage() error{InvalidArguments} {
    std.debug.print("usage: upcontentc <project-directory> [output-directory]\n", .{});
    return error.InvalidArguments;
}
