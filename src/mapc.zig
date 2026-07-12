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
    var map = if (std.mem.endsWith(u8, input, ".tmj"))
        try up.TileMap.loadTiled(gpa.allocator(), input)
    else if (std.mem.endsWith(u8, input, ".ldtk")) blk: {
        var project = try up.TileMap.loadLdtkProject(gpa.allocator(), input);
        errdefer project.deinit();
        if (project.levels.items.len != 1) return error.LdtkProjectRequiresOneLevel;
        const level = project.levels.orderedRemove(0);
        gpa.allocator().free(level.identifier);
        project.deinit();
        break :blk level.map;
    } else try up.TileMap.loadNative(gpa.allocator(), input);
    defer map.deinit();
    try map.writeBinary(output);
}
