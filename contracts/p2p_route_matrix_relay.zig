const std = @import("std");
const matrix = @import("p2p-route-matrix-common");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 2) return error.InvalidArgument;
    try matrix.runRelay(try matrix.parsePort(args[1]));
}
