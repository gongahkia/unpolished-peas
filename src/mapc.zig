const std = @import("std");
const up = @import("unpolished-peas");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var args = try std.process.argsWithAllocator(gpa.allocator());
    defer args.deinit();
    _ = args.next();
    const input = args.next() orelse return error.MissingInput;
    const output = args.next() orelse return error.MissingOutput;
    if (args.next() != null) return error.TooManyArguments;
    var map = try up.TileMap.loadNative(gpa.allocator(), input);
    defer map.deinit();
    try map.writeBinary(output);
}
