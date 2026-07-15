const std = @import("std");
const tools = @import("unpolished-peas-tools");
const content = @import("unpolished-peas-content");
const starter = @import("starter.zig");

const max_build_output_bytes = 8 * 1024 * 1024;

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
        .compile => {
            try compileProject(allocator, args);
            return null;
        },
        .migrate => {
            try migrateContent(allocator, args);
            return null;
        },
        .import_tiled => return error.TiledSupportRemoved,
        .import_ldtk => return error.LdtkSupportRemoved,
        .run => return try runProject(allocator, args),
        .host => {
            try hostRuntime(allocator, args);
            return null;
        },
        .@"test" => return try testProject(allocator, args),
        .package => return try packageProject(allocator, args),
        .docs => return try docsProject(allocator, args),
    }
}

fn hostRuntime(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    var arguments = std.ArrayList([]const u8).empty;
    defer arguments.deinit(allocator);
    while (args.next()) |argument| try arguments.append(allocator, argument);
    const config = tools.parseHostRuntimeConfig(arguments.items) catch return hostUsage();
    std.debug.print("peas host: validated {s} bind {s}:{d} max-peers {d} ticks {d}\npeas host: sample target `zig build run-topdown-{s}`\n", .{ @tagName(config.mode), config.bind_address, config.port, config.max_peers, config.ticks, @tagName(config.mode) });
}

fn hostUsage() error{InvalidArguments} {
    std.debug.print("usage: zig build peas -- host <dedicated|listen> [--bind <ip>] [--port <u16>] [--max-peers <1..64>] [--ticks <1..100000>]\n", .{});
    return error.InvalidArguments;
}

fn migrateContent(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    const kind_argument = args.next() orelse return migrateUsage();
    const kind = std.meta.stringToEnum(content.migration.Kind, kind_argument) orelse return migrateUsage();
    const input_path = args.next() orelse return migrateUsage();
    const output_path = args.next() orelse return migrateUsage();
    if (args.next() != null) return migrateUsage();
    const source = try std.fs.cwd().readFileAlloc(allocator, input_path, 64 * 1024 * 1024);
    defer allocator.free(source);
    var diagnostic = content.migration.Diagnostic{};
    var result = content.migration.migrate(allocator, kind, source, &diagnostic) catch |err| {
        std.debug.print("peas migrate: {s}: {d}:{d}: {s}\n", .{ input_path, diagnostic.line, diagnostic.column, diagnostic.message });
        return err;
    };
    defer result.deinit();
    try std.fs.cwd().writeFile(.{ .sub_path = output_path, .data = result.source });
    std.debug.print("peas migrate: {s} -> {s}: {s}\n", .{ input_path, output_path, if (result.changed) "migrated" else "already current" });
}

fn migrateUsage() error{InvalidArguments} {
    std.debug.print("usage: zig build peas -- migrate <scene|catalog|map> <input> <output>\n", .{});
    return error.InvalidArguments;
}

fn compileProject(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    const project_path = args.next() orelse ".";
    const output_argument = args.next();
    if (args.next() != null) return compileUsage();
    const project_root = tools.discoverProject(allocator, project_path) catch |err| {
        std.debug.print("peas compile: no project build.zig found from {s}\n", .{project_path});
        return err;
    };
    defer allocator.free(project_root);
    const output_root = if (output_argument) |value|
        try absolutePath(allocator, value)
    else
        try std.fs.path.join(allocator, &.{ project_root, "zig-out", "content" });
    defer allocator.free(output_root);
    var diagnostic = content.Diagnostic{};
    defer diagnostic.deinit(allocator);
    const report = content.compileProject(allocator, project_root, output_root, &diagnostic) catch |err| {
        if (diagnostic.path) |path| std.debug.print("peas compile: {s}:{d}:{d}: {s}\n", .{ path, diagnostic.line, diagnostic.column, diagnostic.message });
        return err;
    };
    std.debug.print("peas compile: compiled {d}, reused {d}, output {s}\n", .{ report.compiled, report.reused, output_root });
}

fn absolutePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, path });
}

fn compileUsage() error{InvalidArguments} {
    std.debug.print("usage: zig build peas -- compile [project-directory] [output-directory]\n", .{});
    return error.InvalidArguments;
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
    return runZigBuild(allocator, command_args.items, project_root);
}

fn checkProject(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    var project_path: []const u8 = ".";
    var project_path_set = false;
    var target: ?tools.CheckTarget = null;
    while (args.next()) |argument| {
        if (std.mem.eql(u8, argument, "--target")) {
            if (target != null) return checkUsage();
            const target_argument = args.next() orelse return checkUsage();
            target = tools.parseCheckTarget(target_argument) orelse {
                std.debug.print("peas check: unsupported target {s}\npeas check: recovery: zig build peas -- check --target windows\n", .{target_argument});
                return error.UnsupportedTarget;
            };
        } else if (!project_path_set) {
            project_path = argument;
            project_path_set = true;
        } else return checkUsage();
    }
    const project_root = tools.discoverProject(allocator, project_path) catch |err| {
        std.debug.print("peas check: no project build.zig found from {s}\npeas check: recovery: zig build peas -- new <directory>\n", .{project_path});
        return err;
    };
    defer allocator.free(project_root);
    if (target) |value| {
        std.debug.print("peas check: target {s}\n", .{@tagName(value)});
        if (tools.targetSetupDiagnostic(value)) |diagnostic| {
            std.debug.print("peas check: unsupported {s} setup: {s}\npeas check: recovery: run `zig build peas -- check {s} --target windows` on Windows 10/11 x64\n", .{ @tagName(value), diagnostic, project_root });
            return error.UnsupportedTarget;
        }
    }
    if (try tools.checkProject(allocator, project_root)) |check_issue| {
        var owned_issue = check_issue;
        defer owned_issue.deinit(allocator);
        std.debug.print("peas check: {s}:{d}:{d}: {s}\n", .{ owned_issue.path, owned_issue.line, owned_issue.column, owned_issue.message });
        try printCheckRecovery(allocator, project_root, owned_issue.kind);
        return error.ProjectCheckFailed;
    }
    std.debug.print("peas check: valid project {s}\n", .{project_root});
}

fn checkUsage() error{InvalidArguments} {
    std.debug.print("usage: zig build peas -- check [project-directory] [--target <linux|macos|windows>]\n", .{});
    return error.InvalidArguments;
}

fn printCheckRecovery(allocator: std.mem.Allocator, project_root: []const u8, kind: tools.CheckIssueKind) !void {
    const command = switch (kind) {
        .missing_assets => try std.fmt.allocPrint(allocator, "mkdir -p \"{s}/assets\" && zig build peas -- check \"{s}\"", .{ project_root, project_root }),
        else => try std.fmt.allocPrint(allocator, "zig build peas -- check \"{s}\"", .{project_root}),
    };
    defer allocator.free(command);
    std.debug.print("peas check: recovery: {s}\n", .{command});
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
    const term = try runZigBuild(allocator, &.{ "zig", "build", step }, project_root);
    if (term == .Exited and term.Exited != 0) {
        std.debug.print("peas test: target {s} failed; artifact directory {s}/zig-out\n", .{ step, project_root });
    }
    return term;
}

fn testUsage() error{InvalidArguments} {
    std.debug.print("usage: zig build peas -- test <unit|replay|visual|integration> [project-directory]\n", .{});
    return error.InvalidArguments;
}

fn packageProject(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !std.process.Child.Term {
    const target_argument = args.next() orelse return packageUsage();
    const target = tools.parsePackageTarget(target_argument) orelse return packageUsage();
    var output_directory: ?[]const u8 = null;
    var game: tools.PackageGame = .bounce;
    var game_set = false;
    while (args.next()) |argument| {
        if (std.mem.eql(u8, argument, "--game")) {
            if (game_set) return packageUsage();
            const game_argument = args.next() orelse return packageUsage();
            game = tools.parsePackageGame(game_argument) orelse return packageUsage();
            game_set = true;
        } else if (output_directory == null) {
            output_directory = argument;
        } else return packageUsage();
    }
    const script_root = std.process.getEnvVarOwned(allocator, "UP_SCRIPT_ROOT") catch return error.PackageUnavailable;
    defer allocator.free(script_root);
    const script_path = try std.fs.path.join(allocator, &.{ script_root, target.scriptName() });
    defer allocator.free(script_path);
    var command_args = std.ArrayList([]const u8).empty;
    defer command_args.deinit(allocator);
    if (target == .windows) {
        if (tools.targetSetupDiagnostic(.windows)) |diagnostic| {
            std.debug.print("peas package: unsupported windows setup: {s}\npeas package: recovery: run `zig build peas -- package windows` on Windows 10/11 x64\n", .{diagnostic});
            return error.UnsupportedTarget;
        }
        try command_args.appendSlice(allocator, &.{ "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script_path });
        if (output_directory) |value| try command_args.appendSlice(allocator, &.{ "-OutputDirectory", value });
        try command_args.appendSlice(allocator, &.{ "-Game", @tagName(game) });
    } else {
        try command_args.append(allocator, script_path);
        if (output_directory) |value| try command_args.append(allocator, value);
        try command_args.appendSlice(allocator, &.{ "--game", @tagName(game) });
    }
    std.debug.print("peas package: target {s}, game {s}\n", .{ @tagName(target), @tagName(game) });
    var child = std.process.Child.init(command_args.items, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    return child.spawnAndWait();
}

fn packageUsage() error{InvalidArguments} {
    std.debug.print("usage: zig build peas -- package <linux|macos|windows> [output-directory] [--game <bounce|topdown|platformer>]\n", .{});
    return error.InvalidArguments;
}

fn docsProject(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !std.process.Child.Term {
    const topic = if (args.next()) |value| tools.parseDocsTopic(value) orelse return docsUsage() else .overview;
    if (args.next() != null) return docsUsage();
    const repository_root = std.process.getEnvVarOwned(allocator, "UP_REPOSITORY_ROOT") catch return error.DocsUnavailable;
    defer allocator.free(repository_root);
    var child = std.process.Child.init(&.{ "zig", "build", "docs" }, allocator);
    child.cwd = repository_root;
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const term = try child.spawnAndWait();
    if (term == .Exited and term.Exited == 0) {
        const path = try std.fs.path.join(allocator, &.{ repository_root, "zig-out", "docs", topic.relativePath() });
        defer allocator.free(path);
        std.debug.print("peas docs: {s}\n", .{path});
    }
    return term;
}

fn docsUsage() error{InvalidArguments} {
    std.debug.print("usage: zig build peas -- docs [overview|quickstart|testing|api]\n", .{});
    return error.InvalidArguments;
}

fn runZigBuild(allocator: std.mem.Allocator, arguments: []const []const u8, cwd: []const u8) !std.process.Child.Term {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = arguments,
        .cwd = cwd,
        .max_output_bytes = max_build_output_bytes,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.fs.File.stdout().writeAll(result.stdout);
    try std.fs.File.stderr().writeAll(result.stderr);
    if (tools.diagnosticRemediation(tools.classifyDiagnostic(result.stderr))) |remediation| {
        if (result.stderr.len != 0 and result.stderr[result.stderr.len - 1] != '\n') try std.fs.File.stderr().writeAll("\n");
        std.debug.print("peas recovery: {s}\n", .{remediation});
    }
    return result.term;
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
    try std.testing.expectEqual(tools.Command.host, tools.parseCommand("host").?);
    try std.testing.expectEqual(tools.Command.check, tools.parseCommand("check").?);
    try std.testing.expectEqual(tools.Command.compile, tools.parseCommand("compile").?);
    try std.testing.expectEqual(tools.Command.migrate, tools.parseCommand("migrate").?);
    try std.testing.expectEqual(tools.Command.import_tiled, tools.parseCommand("import-tiled").?);
    try std.testing.expectEqual(tools.Command.import_ldtk, tools.parseCommand("import-ldtk").?);
    try std.testing.expectEqual(tools.Command.@"test", tools.parseCommand("test").?);
    try std.testing.expectEqual(tools.Command.package, tools.parseCommand("package").?);
    try std.testing.expectEqual(tools.Command.docs, tools.parseCommand("docs").?);
}

test "known test selections parse" {
    try std.testing.expectEqual(tools.TestSelection.unit, tools.parseTestSelection("unit").?);
    try std.testing.expectEqual(tools.TestSelection.replay, tools.parseTestSelection("replay").?);
    try std.testing.expectEqual(tools.TestSelection.visual, tools.parseTestSelection("visual").?);
    try std.testing.expectEqual(tools.TestSelection.integration, tools.parseTestSelection("integration").?);
}

test "known package targets parse" {
    try std.testing.expectEqual(tools.PackageTarget.linux, tools.parsePackageTarget("linux").?);
    try std.testing.expectEqual(tools.PackageTarget.macos, tools.parsePackageTarget("macos").?);
    try std.testing.expectEqual(tools.PackageTarget.windows, tools.parsePackageTarget("windows").?);
}

test "known package games parse" {
    try std.testing.expectEqual(tools.PackageGame.bounce, tools.parsePackageGame("bounce").?);
    try std.testing.expectEqual(tools.PackageGame.topdown, tools.parsePackageGame("topdown").?);
    try std.testing.expectEqual(tools.PackageGame.platformer, tools.parsePackageGame("platformer").?);
}

test "known check targets parse" {
    try std.testing.expectEqual(tools.CheckTarget.windows, tools.parseCheckTarget("windows").?);
}

test "known docs topics parse" {
    try std.testing.expectEqual(tools.DocsTopic.overview, tools.parseDocsTopic("overview").?);
    try std.testing.expectEqual(tools.DocsTopic.quickstart, tools.parseDocsTopic("quickstart").?);
    try std.testing.expectEqual(tools.DocsTopic.testing, tools.parseDocsTopic("testing").?);
    try std.testing.expectEqual(tools.DocsTopic.api, tools.parseDocsTopic("api").?);
}

test "unknown command is rejected" {
    try std.testing.expect(tools.parseCommand("publish") == null);
}

test "new command rejects invalid destinations" {
    try std.testing.expectError(error.InvalidDestination, starter.validateDestination(""));
}
