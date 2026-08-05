const std = @import("std");
const exchange = @import("udp-cross-process-common");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 3) return error.InvalidArgument;
    try exchange.run(.client, try exchange.parsePort(args[1]), try exchange.parsePort(args[2]));
}
