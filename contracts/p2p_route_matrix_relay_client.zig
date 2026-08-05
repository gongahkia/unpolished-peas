const std = @import("std");
const matrix = @import("p2p-route-matrix-common");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 3) return error.InvalidArgument;
    try matrix.runRelayPeer(.client, try matrix.parsePort(args[1]), try matrix.parsePort(args[2]));
}
