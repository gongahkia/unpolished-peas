const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 2) return error.InvalidArguments;

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = args[1..],
        .max_output_bytes = 64 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term == .Exited and result.term.Exited == 0) return error.ForbiddenImportCompiled;
    if (!std.mem.containsAtLeast(u8, result.stderr, 1, "no module named 'minna-san-runtime'")) return error.UnexpectedCompilerFailure;
}
