const std = @import("std");

pub const Command = enum {
    new,
    run,
    check,
    @"test",
    package,
};

pub fn parseCommand(value: []const u8) ?Command {
    return std.meta.stringToEnum(Command, value);
}

pub fn printHelp() void {
    std.debug.print(
        \\usage: zig build peas -- <command> [args]
        \\commands: new run check test package
        \\use `zig build peas -- help` for this message
        \\ 
    , .{});
}

test "tools module parses CLI commands without runtime imports" {
    try std.testing.expectEqual(Command.new, parseCommand("new").?);
    try std.testing.expect(parseCommand("publish") == null);
}
