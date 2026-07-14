const std = @import("std");
const tools = @import("unpolished-peas-tools");
const starter = @import("starter.zig");

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
    try dispatch(gpa.allocator(), command, &args);
}

fn dispatch(allocator: std.mem.Allocator, command: tools.Command, args: *std.process.ArgIterator) !void {
    switch (command) {
        .new => try createProject(allocator, args),
        else => {
            while (args.next()) |_| {}
            std.debug.print("peas {s}: command registered but not implemented yet\n", .{@tagName(command)});
            return error.CommandNotImplemented;
        },
    }
}

fn createProject(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    const destination = args.next() orelse return newUsage();
    if (args.next() != null) return newUsage();
    const template_root = std.process.getEnvVarOwned(allocator, "UP_TEMPLATE_ROOT") catch return error.TemplateUnavailable;
    defer allocator.free(template_root);
    starter.createProject(allocator, template_root, destination) catch |err| {
        switch (err) {
            error.InvalidDestination => std.debug.print("peas new: destination must name a new project directory\n", .{}),
            error.DestinationExists => std.debug.print("peas new: destination already exists: {s}\n", .{destination}),
            else => std.debug.print("peas new: failed to create {s}: {s}\n", .{ destination, @errorName(err) }),
        }
        return err;
    };
    std.debug.print("created unpolished-peas project: {s}\n", .{destination});
}

fn newUsage() error{InvalidArguments} {
    std.debug.print("usage: zig build peas -- new <directory>\n", .{});
    return error.InvalidArguments;
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

test "new command rejects invalid destinations" {
    try std.testing.expectError(error.InvalidDestination, starter.validateDestination(""));
}
