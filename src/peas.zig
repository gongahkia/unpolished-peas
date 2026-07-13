const std = @import("std");

const Command = enum {
    new,
    run,
    check,
    @"test",
    package,
};

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
    const command = parseCommand(argument) orelse {
        std.debug.print("peas: unknown command '{s}'\n", .{argument});
        return usage();
    };
    try dispatch(command, &args);
}

fn parseCommand(value: []const u8) ?Command {
    return std.meta.stringToEnum(Command, value);
}

fn dispatch(command: Command, args: *std.process.ArgIterator) !void {
    while (args.next()) |_| {}
    std.debug.print("peas {s}: command registered but not implemented yet\n", .{@tagName(command)});
    return error.CommandNotImplemented;
}

fn usage() error{InvalidArguments} {
    printHelp();
    return error.InvalidArguments;
}

fn printHelp() void {
    std.debug.print(
        \\usage: zig build peas -- <command> [args]
        \\commands: new run check test package
        \\use `zig build peas -- help` for this message
        \\ 
    , .{});
}

test "known commands parse" {
    try std.testing.expectEqual(Command.new, parseCommand("new").?);
    try std.testing.expectEqual(Command.run, parseCommand("run").?);
    try std.testing.expectEqual(Command.check, parseCommand("check").?);
    try std.testing.expectEqual(Command.@"test", parseCommand("test").?);
    try std.testing.expectEqual(Command.package, parseCommand("package").?);
}

test "unknown command is rejected" {
    try std.testing.expect(parseCommand("publish") == null);
}
