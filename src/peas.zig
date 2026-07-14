const std = @import("std");
const tools = @import("unpolished-peas-tools");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var args = try std.process.argsWithAllocator(gpa.allocator());
    defer args.deinit();
    _ = args.next();
    const argument = args.next() orelse return usage();
    if (std.mem.eql(u8, argument, "help") or std.mem.eql(u8, argument, "--help") or std.mem.eql(u8, argument, "-h")) {
        printHelp();
        return;
    }
    const command = tools.parseCommand(argument) orelse {
        std.debug.print("peas: unknown command '{s}'\n", .{argument});
        return usage();
    };
    try dispatch(command, &args);
}

fn dispatch(command: tools.Command, args: *std.process.ArgIterator) !void {
    while (args.next()) |_| {}
    std.debug.print("peas {s}: command registered but not implemented yet\n", .{@tagName(command)});
    return error.CommandNotImplemented;
}

fn usage() error{InvalidArguments} {
    printHelp();
    return error.InvalidArguments;
}

fn printHelp() void {
    tools.printHelp();
}

test "known commands parse" {
    try std.testing.expectEqual(tools.Command.new, tools.parseCommand("new").?);
    try std.testing.expectEqual(tools.Command.run, tools.parseCommand("run").?);
    try std.testing.expectEqual(tools.Command.check, tools.parseCommand("check").?);
    try std.testing.expectEqual(tools.Command.@"test", tools.parseCommand("test").?);
    try std.testing.expectEqual(tools.Command.package, tools.parseCommand("package").?);
}

test "unknown command is rejected" {
    try std.testing.expect(tools.parseCommand("publish") == null);
}
