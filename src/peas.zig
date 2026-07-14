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
    const term = try dispatch(gpa.allocator(), command, &args);
    if (term) |value| switch (value) {
        .Exited => |code| if (code != 0) std.process.exit(code),
        else => return error.ProjectRunFailed,
    };
}

fn dispatch(allocator: std.mem.Allocator, command: tools.Command, args: *std.process.ArgIterator) !?std.process.Child.Term {
    switch (command) {
        .new => {
            try createProject(allocator, args);
            return null;
        },
        .check => {
            try checkProject(allocator, args);
            return null;
        },
        .run => return try runProject(allocator, args),
        .@"test" => return try testProject(allocator, args),
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

fn runProject(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !std.process.Child.Term {
    const first = args.next();
    const project_path = if (first) |value| if (std.mem.eql(u8, value, "--")) "." else value else ".";
    const separator_consumed = first != null and std.mem.eql(u8, first.?, "--");
    if (!separator_consumed) if (args.next()) |value| if (!std.mem.eql(u8, value, "--")) return runUsage();

    var game_args = std.ArrayList([]const u8).empty;
    defer game_args.deinit(allocator);
    while (args.next()) |value| try game_args.append(allocator, value);
    const project_root = tools.discoverProject(allocator, project_path) catch |err| {
        std.debug.print("peas run: no project build.zig found from {s}\n", .{project_path});
        return err;
    };
    defer allocator.free(project_root);
    tools.validateProjectAssets(allocator, project_root) catch |err| {
        if (err == error.ProjectAssetsMissing) std.debug.print("peas run: required assets directory missing: {s}/assets\n", .{project_root});
        return err;
    };
    std.debug.print("peas run: project {s}\npeas run: assets {s}/assets\npeas run: Debug runtime logs and app-data path follow\n", .{ project_root, project_root });

    var command_args = std.ArrayList([]const u8).empty;
    defer command_args.deinit(allocator);
    try command_args.appendSlice(allocator, &.{ "zig", "build", "-Doptimize=Debug", "run", "--" });
    try command_args.appendSlice(allocator, game_args.items);
    var child = std.process.Child.init(command_args.items, allocator);
    child.cwd = project_root;
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    return child.spawnAndWait();
}

fn checkProject(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    const project_path = args.next() orelse ".";
    if (args.next() != null) return checkUsage();
    const project_root = tools.discoverProject(allocator, project_path) catch |err| {
        std.debug.print("peas check: no project build.zig found from {s}\n", .{project_path});
        return err;
    };
    defer allocator.free(project_root);
    if (try tools.checkProject(allocator, project_root)) |check_issue| {
        var owned_issue = check_issue;
        defer owned_issue.deinit(allocator);
        std.debug.print("peas check: {s}:{d}:{d}: {s}\n", .{ owned_issue.path, owned_issue.line, owned_issue.column, owned_issue.message });
        return error.ProjectCheckFailed;
    }
    std.debug.print("peas check: valid project {s}\n", .{project_root});
}

fn checkUsage() error{InvalidArguments} {
    std.debug.print("usage: zig build peas -- check [project-directory]\n", .{});
    return error.InvalidArguments;
}

fn testProject(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !std.process.Child.Term {
    const selection_argument = args.next() orelse return testUsage();
    const selection = tools.parseTestSelection(selection_argument) orelse return testUsage();
    const project_path = args.next() orelse ".";
    if (args.next() != null) return testUsage();
    const project_root = tools.discoverProject(allocator, project_path) catch |err| {
        std.debug.print("peas test: no project build.zig found from {s}\n", .{project_path});
        return err;
    };
    defer allocator.free(project_root);
    const step = selection.buildStep();
    std.debug.print("peas test: target {s}\npeas test: artifact directory {s}/zig-out\n", .{ step, project_root });
    var child = std.process.Child.init(&.{ "zig", "build", step }, allocator);
    child.cwd = project_root;
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const term = try child.spawnAndWait();
    if (term == .Exited and term.Exited != 0) {
        std.debug.print("peas test: target {s} failed; artifact directory {s}/zig-out\n", .{ step, project_root });
    }
    return term;
}

fn testUsage() error{InvalidArguments} {
    std.debug.print("usage: zig build peas -- test <unit|replay|visual|integration> [project-directory]\n", .{});
    return error.InvalidArguments;
}

fn runUsage() error{InvalidArguments} {
    std.debug.print("usage: zig build peas -- run [project-directory] -- [game-args]\n", .{});
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

test "known test selections parse" {
    try std.testing.expectEqual(tools.TestSelection.unit, tools.parseTestSelection("unit").?);
    try std.testing.expectEqual(tools.TestSelection.replay, tools.parseTestSelection("replay").?);
    try std.testing.expectEqual(tools.TestSelection.visual, tools.parseTestSelection("visual").?);
    try std.testing.expectEqual(tools.TestSelection.integration, tools.parseTestSelection("integration").?);
}

test "unknown command is rejected" {
    try std.testing.expect(tools.parseCommand("publish") == null);
}

test "new command rejects invalid destinations" {
    try std.testing.expectError(error.InvalidDestination, starter.validateDestination(""));
}
