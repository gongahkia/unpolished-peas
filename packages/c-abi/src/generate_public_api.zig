const std = @import("std");
const inventory = @import("public_api_inventory.zig");

const header_prefix = "#ifndef MINNA_SAN_API_H\n#define MINNA_SAN_API_H\n\n";
const header_suffix = "\n#endif\n";

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--symbols")) return emitSymbols();
    if (args.len == 2 and std.mem.eql(u8, args[1], "--render")) return emitHeader(allocator);
    if (args.len != 4 or !std.mem.eql(u8, args[1], "--check")) return error.InvalidArguments;
    const source = try std.fs.cwd().readFileAlloc(allocator, args[2], 1024 * 1024);
    defer allocator.free(source);
    try validateExports(source);
    var rendered = std.ArrayList(u8).empty;
    defer rendered.deinit(allocator);
    try render(&rendered, allocator);
    const header = try std.fs.cwd().readFileAlloc(allocator, args[3], 1024 * 1024);
    defer allocator.free(header);
    if (!std.mem.eql(u8, rendered.items, header)) return error.GeneratedHeaderMismatch;
}

fn emitSymbols() !void {
    const writer = std.fs.File.stdout().deprecatedWriter();
    for (inventory.declarations) |declaration| try writer.print("{s}\n", .{declaration.name});
}

fn emitHeader(allocator: std.mem.Allocator) !void {
    var rendered = std.ArrayList(u8).empty;
    defer rendered.deinit(allocator);
    try render(&rendered, allocator);
    try std.fs.File.stdout().deprecatedWriter().writeAll(rendered.items);
}

fn render(output: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    try output.appendSlice(allocator, header_prefix);
    for (inventory.declarations) |declaration| {
        try output.appendSlice(allocator, declaration.c);
        try output.append(allocator, '\n');
    }
    try output.appendSlice(allocator, header_suffix);
}

fn validateExports(source: []const u8) !void {
    for (inventory.declarations) |declaration| {
        var marker: [128]u8 = undefined;
        const expected = try std.fmt.bufPrint(&marker, "pub export fn {s}(", .{declaration.name});
        if (occurrences(source, expected) != 1) return error.InventoryExportMismatch;
    }
    var position: usize = 0;
    const prefix = "pub export fn ";
    while (std.mem.indexOfPos(u8, source, position, prefix)) |start| {
        const name_start = start + prefix.len;
        const suffix = source[name_start..];
        const name_end = std.mem.indexOfScalar(u8, suffix, '(') orelse return error.InvalidExport;
        if (!containsName(suffix[0..name_end])) return error.UninventoriedExport;
        position = name_start + name_end + 1;
    }
}

fn containsName(name: []const u8) bool {
    for (inventory.declarations) |declaration| if (std.mem.eql(u8, declaration.name, name)) return true;
    return false;
}

fn occurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var position: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, position, needle)) |start| {
        count += 1;
        position = start + needle.len;
    }
    return count;
}
