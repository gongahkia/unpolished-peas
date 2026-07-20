const std = @import("std");
const tools = @import("unpolished-peas-tools");
const input_replay = @import("input_replay.zig");
const starter = @import("starter.zig");
const support_bundle = @import("support_bundle.zig");

const max_build_output_bytes = 8 * 1024 * 1024;
const max_replay_bytes = 1024 * 1024;

const CliMode = struct {
    json: bool = false,
    non_interactive: bool = false,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var args = try std.process.argsWithAllocator(gpa.allocator());
    defer args.deinit();
    _ = args.next();
    var mode = CliMode{};
    var argument = args.next() orelse return usage();
    while (std.mem.eql(u8, argument, "--json") or std.mem.eql(u8, argument, "--non-interactive")) {
        if (std.mem.eql(u8, argument, "--json")) mode.json = true else mode.non_interactive = true;
        argument = args.next() orelse {
            if (mode.json) {
                try emitJson(gpa.allocator(), null, .failed, "invalid_arguments", mode);
                std.process.exit(64);
            }
            return usage();
        };
    }
    if (std.mem.eql(u8, argument, "help") or std.mem.eql(u8, argument, "--help") or std.mem.eql(u8, argument, "-h")) {
        printHelp();
        return;
    }
    const command = tools.parseCommand(argument) orelse {
        std.debug.print("peas: unknown command '{s}'\n", .{argument});
        if (mode.json) {
            try emitJson(gpa.allocator(), null, .failed, "unknown_command", mode);
            std.process.exit(64);
        }
        return usage();
    };
    if (mode.non_interactive and (command == .run or command == .serve)) {
        if (mode.json) {
            try emitJson(gpa.allocator(), command, .failed, "interactive_command", mode);
            std.process.exit(65);
        }
        return error.NonInteractiveCommand;
    }
    if (command == .doctor) {
        const code = doctorEnvironment(gpa.allocator(), &args) catch |err| {
            if (mode.json) {
                try emitJson(gpa.allocator(), command, .failed, recoveryCode(err), mode);
                std.process.exit(recoveryExitCode(err));
            }
            return err;
        };
        if (mode.json) try emitJson(gpa.allocator(), command, if (code == 0) .ok else .failed, if (code == 0) "ok" else doctorRecoveryCode(code), mode);
        if (code != 0) std.process.exit(code);
        return;
    }
    const term = dispatch(gpa.allocator(), command, &args, mode) catch |err| {
        if (mode.json) {
            try emitJson(gpa.allocator(), command, .failed, recoveryCode(err), mode);
            std.process.exit(recoveryExitCode(err));
        }
        return err;
    };
    if (term) |value| switch (value) {
        .Exited => |code| if (code != 0) {
            if (mode.json) {
                try emitJson(gpa.allocator(), command, .failed, "child_failed", mode);
                std.process.exit(1);
            }
            std.process.exit(code);
        },
        else => {
            if (mode.json) {
                try emitJson(gpa.allocator(), command, .failed, "child_failed", mode);
                std.process.exit(1);
            }
            return error.ProjectRunFailed;
        },
    };
    if (mode.json) try emitJson(gpa.allocator(), command, .ok, "ok", mode);
}

fn dispatch(allocator: std.mem.Allocator, command: tools.Command, args: *std.process.ArgIterator, mode: CliMode) !?std.process.Child.Term {
    switch (command) {
        .new => {
            try createProject(allocator, args);
            return null;
        },
        .check => {
            try checkProject(allocator, args);
            return null;
        },
        .run => return try runProject(allocator, args, mode),
        .@"test" => return try testProject(allocator, args, mode),
        .replay => {
            try replayFixture(allocator, args);
            return null;
        },
        .package => return try packageProject(allocator, args, mode),
        .serve => return try serveBundle(allocator, args, mode),
        .support_bundle => {
            try exportSupportBundle(allocator, args);
            return null;
        },
        .docs => return try docsProject(allocator, args, mode),
        .doctor => unreachable,
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

fn runProject(allocator: std.mem.Allocator, args: *std.process.ArgIterator, mode: CliMode) !std.process.Child.Term {
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

    const command_args = try debugRunArguments(allocator, game_args.items);
    defer allocator.free(command_args);
    return runZigBuild(allocator, command_args, project_root, mode);
}

fn debugRunArguments(allocator: std.mem.Allocator, game_args: []const []const u8) ![]const []const u8 {
    var command_args = std.ArrayList([]const u8).empty;
    errdefer command_args.deinit(allocator);
    try command_args.appendSlice(allocator, &.{ "zig", "build", "-Doptimize=Debug", "run", "--" });
    try command_args.appendSlice(allocator, game_args);
    return command_args.toOwnedSlice(allocator);
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

fn testProject(allocator: std.mem.Allocator, args: *std.process.ArgIterator, mode: CliMode) !std.process.Child.Term {
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
    const report = try testTargetReport(allocator, selection, project_root);
    defer allocator.free(report);
    std.debug.print("{s}", .{report});
    const term = try runZigBuild(allocator, &.{ "zig", "build", step }, project_root, mode);
    if (term == .Exited and term.Exited != 0) {
        std.debug.print("peas test: class={s} target={s} status=failed artifacts={s}/zig-out\n", .{ @tagName(selection), step, project_root });
    }
    return term;
}

fn testTargetReport(allocator: std.mem.Allocator, selection: tools.TestSelection, project_root: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "peas test: class={s} target={s} artifacts={s}/zig-out\n", .{ @tagName(selection), selection.buildStep(), project_root });
}

fn testUsage() error{InvalidArguments} {
    std.debug.print("usage: zig build peas -- test <unit|replay|visual|integration> [project-directory]\n", .{});
    return error.InvalidArguments;
}

fn replayFixture(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    const path = args.next() orelse return replayUsage();
    const expected_argument = args.next();
    if (args.next() != null) return replayUsage();
    const source = std.fs.cwd().readFileAlloc(allocator, path, max_replay_bytes) catch |err| {
        std.debug.print("peas replay: unable to read {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    defer allocator.free(source);
    var value = input_replay.parse(allocator, source) catch |err| {
        std.debug.print("peas replay: invalid fixture {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    defer value.deinit(allocator);
    const expected = if (expected_argument) |argument| parseReplayHash(argument) catch return replayUsage() else null;
    const result = try input_replay.reproduce(value);
    const report = try replayReport(allocator, result, expected);
    defer allocator.free(report);
    std.debug.print("{s}", .{report});
    if (expected) |hash| if (hash != result.hash) return error.ReplayDiverged;
}

fn replayUsage() error{InvalidArguments} {
    std.debug.print("usage: zig build peas -- replay <fixture.upr> [expected-input-hash]\n", .{});
    return error.InvalidArguments;
}

fn parseReplayHash(value: []const u8) !u64 {
    const digits = if (std.mem.startsWith(u8, value, "0x")) value[2..] else value;
    if (digits.len == 0) return error.InvalidReplayHash;
    return std.fmt.parseInt(u64, digits, 16);
}

fn replayReport(allocator: std.mem.Allocator, result: input_replay.Reproduction, expected: ?u64) ![]u8 {
    if (expected) |value| {
        return std.fmt.allocPrint(allocator, "peas replay: frames={d} fixed-hz={d} updates={d} hash=0x{x}\npeas replay: expected=0x{x} actual=0x{x} divergence={s}\n", .{ result.frames, result.fixed_hz, result.updates, result.hash, value, result.hash, if (value == result.hash) "none" else "final-state" });
    }
    return std.fmt.allocPrint(allocator, "peas replay: frames={d} fixed-hz={d} updates={d} hash=0x{x}\n", .{ result.frames, result.fixed_hz, result.updates, result.hash });
}

fn packageProject(allocator: std.mem.Allocator, args: *std.process.ArgIterator, mode: CliMode) !std.process.Child.Term {
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
    child.stdin_behavior = if (mode.non_interactive) .Ignore else .Inherit;
    child.stdout_behavior = if (mode.json) .Ignore else .Inherit;
    child.stderr_behavior = .Inherit;
    return child.spawnAndWait();
}

fn packageUsage() error{InvalidArguments} {
    std.debug.print("usage: zig build peas -- package <linux|macos|windows|web> [output-directory] [--game <bounce|topdown|puzzle>]\n", .{});
    return error.InvalidArguments;
}

fn serveBundle(allocator: std.mem.Allocator, args: *std.process.ArgIterator, mode: CliMode) !std.process.Child.Term {
    var path: []const u8 = "dist/web/unpolished-peas-bounce-web";
    var port: []const u8 = "8000";
    var path_set = false;
    while (args.next()) |argument| {
        if (std.mem.eql(u8, argument, "--port")) {
            const value = args.next() orelse return serveUsage();
            const parsed = std.fmt.parseInt(u16, value, 10) catch return serveUsage();
            if (parsed == 0) return serveUsage();
            port = value;
        } else if (!path_set) {
            path = argument;
            path_set = true;
        } else return serveUsage();
    }
    const root = try std.fs.cwd().realpathAlloc(allocator, path);
    defer allocator.free(root);
    const index = try std.fs.path.join(allocator, &.{ root, "index.html" });
    defer allocator.free(index);
    std.fs.cwd().access(index, .{}) catch return error.WebBundleMissing;
    std.debug.print("peas serve: http://127.0.0.1:{s}/\n", .{port});
    var child = std.process.Child.init(&.{ "python3", "-m", "http.server", port, "--bind", "127.0.0.1", "--directory", root }, allocator);
    child.stdin_behavior = if (mode.non_interactive) .Ignore else .Inherit;
    child.stdout_behavior = if (mode.json) .Ignore else .Inherit;
    child.stderr_behavior = .Inherit;
    return child.spawnAndWait();
}

fn serveUsage() error{InvalidArguments} {
    std.debug.print("usage: zig build peas -- serve [web-bundle-directory] [--port <1-65535>]\n", .{});
    return error.InvalidArguments;
}

fn exportSupportBundle(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    const source_path = args.next() orelse return supportBundleUsage();
    const output_path = args.next() orelse return supportBundleUsage();
    var include = std.ArrayList([]const u8).empty;
    defer include.deinit(allocator);
    var redact = std.ArrayList([]const u8).empty;
    defer redact.deinit(allocator);
    var redact_paths = std.ArrayList([]const u8).empty;
    defer redact_paths.deinit(allocator);
    while (args.next()) |argument| {
        const values = if (std.mem.eql(u8, argument, "--include")) &include else if (std.mem.eql(u8, argument, "--redact")) &redact else if (std.mem.eql(u8, argument, "--redact-path")) &redact_paths else return supportBundleUsage();
        const value = args.next() orelse return supportBundleUsage();
        try values.append(allocator, value);
    }
    const report = support_bundle.create(allocator, .{ .source_path = source_path, .output_path = output_path, .include = include.items, .redact = redact.items, .redact_paths = redact_paths.items }) catch |err| {
        std.debug.print("peas support-bundle: failed: {s}\n", .{@errorName(err)});
        return err;
    };
    std.debug.print("peas support-bundle: local export {s}: files={d} redactions={d}\n", .{ output_path, report.files, report.redacted_occurrences });
}

fn supportBundleUsage() error{InvalidArguments} {
    std.debug.print("usage: zig build peas -- support-bundle <diagnostics-directory> <output-directory> [--include <artifact>]... [--redact <literal>]... [--redact-path <path>]...\n", .{});
    return error.InvalidArguments;
}

const DoctorCode = enum(u8) {
    ok = 0,
    project = 20,
    zig = 21,
    target = 22,
    renderer = 23,
    assets = 24,
    browser_host = 25,
    package = 26,
};

fn doctorEnvironment(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !u8 {
    var project_path: []const u8 = ".";
    var project_path_set = false;
    var target = tools.defaultDoctorTarget() orelse {
        printDoctor(.target, "unsupported host target");
        return @intFromEnum(DoctorCode.target);
    };
    var renderer: tools.DoctorRenderer = .auto;
    var package_target: ?tools.DoctorTarget = null;
    while (args.next()) |argument| {
        if (std.mem.eql(u8, argument, "--target")) {
            target = tools.parseDoctorTarget(args.next() orelse return doctorUsage()) orelse return doctorUsage();
        } else if (std.mem.eql(u8, argument, "--renderer")) {
            renderer = tools.parseDoctorRenderer(args.next() orelse return doctorUsage()) orelse return doctorUsage();
        } else if (std.mem.eql(u8, argument, "--package")) {
            package_target = tools.parseDoctorTarget(args.next() orelse return doctorUsage()) orelse return doctorUsage();
        } else if (!project_path_set) {
            project_path = argument;
            project_path_set = true;
        } else return doctorUsage();
    }
    const project_root = tools.discoverProject(allocator, project_path) catch {
        printDoctor(.project, "project build.zig not found");
        return @intFromEnum(DoctorCode.project);
    };
    defer allocator.free(project_root);
    if (try tools.checkProject(allocator, project_root)) |issue| {
        var owned = issue;
        defer owned.deinit(allocator);
        const code: DoctorCode = switch (owned.kind) {
            .incompatible_zig => .zig,
            .missing_assets => .assets,
            else => .project,
        };
        std.debug.print("peas doctor: check={s} status=failed code={d} detail={s}:{d}:{d}: {s}\n", .{ @tagName(code), @intFromEnum(code), owned.path, owned.line, owned.column, owned.message });
        return @intFromEnum(code);
    }
    if (!tools.supportedZigVersion()) {
        printDoctor(.zig, "unsupported Zig compiler version");
        return @intFromEnum(DoctorCode.zig);
    }
    if (tools.doctorTargetDiagnostic(target)) |diagnostic| {
        printDoctor(.target, diagnostic);
        return @intFromEnum(DoctorCode.target);
    }
    if (tools.doctorRendererDiagnostic(target, renderer)) |diagnostic| {
        printDoctor(.renderer, diagnostic);
        return @intFromEnum(DoctorCode.renderer);
    }
    if (!browserHostReady(allocator)) {
        printDoctor(.browser_host, "node executable is unavailable");
        return @intFromEnum(DoctorCode.browser_host);
    }
    const selected_package = package_target orelse target;
    if (packagePrerequisiteDiagnostic(allocator, selected_package)) |diagnostic| {
        printDoctor(.package, diagnostic);
        return @intFromEnum(DoctorCode.package);
    }
    std.debug.print("peas doctor: status=ok zig={s} target={s} renderer={s} browser-host=node package={s}\n", .{ @import("builtin").zig_version_string, @tagName(target), @tagName(renderer), @tagName(selected_package) });
    return @intFromEnum(DoctorCode.ok);
}

fn browserHostReady(allocator: std.mem.Allocator) bool {
    return commandWorks(allocator, &.{ "node", "--version" });
}

fn packagePrerequisiteDiagnostic(allocator: std.mem.Allocator, target: tools.DoctorTarget) ?[]const u8 {
    const script_root = std.process.getEnvVarOwned(allocator, "UP_SCRIPT_ROOT") catch return "UP_SCRIPT_ROOT is unavailable";
    defer allocator.free(script_root);
    const script_path = std.fs.path.join(allocator, &.{ script_root, target.packageScriptName() }) catch return "package script path is invalid";
    defer allocator.free(script_path);
    std.fs.cwd().access(script_path, .{}) catch return "package script is unavailable";
    switch (target) {
        .linux => {
            if (!commandWorks(allocator, &.{ "tar", "--version" })) return "missing GNU tar";
            if (!commandWorks(allocator, &.{ "gzip", "--version" })) return "missing gzip";
            if (!commandWorks(allocator, &.{ "sha256sum", "--version" })) return "missing sha256sum";
        },
        .macos => {
            if (!commandWorks(allocator, &.{ "xcrun", "--show-sdk-path" })) return "missing macOS SDK";
            if (!commandWorks(allocator, &.{ "xcrun", "--find", "lipo" })) return "missing lipo";
            if (!commandWorks(allocator, &.{ "zip", "-v" })) return "missing zip";
            if (!commandWorks(allocator, &.{ "shasum", "-a", "256", "/dev/null" })) return "missing shasum";
        },
        .windows => if (!commandWorks(allocator, &.{ "powershell.exe", "-NoProfile", "-Command", "$PSVersionTable.PSVersion" })) return "missing PowerShell",
        .web => if (!browserHostReady(allocator)) return "missing Node browser host",
    }
    return null;
}

fn commandWorks(allocator: std.mem.Allocator, argv: []const []const u8) bool {
    const result = std.process.Child.run(.{ .allocator = allocator, .argv = argv, .max_output_bytes = 4096 }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn printDoctor(code: DoctorCode, detail: []const u8) void {
    std.debug.print("peas doctor: check={s} status=failed code={d} detail={s}\n", .{ @tagName(code), @intFromEnum(code), detail });
}

fn doctorUsage() error{InvalidArguments} {
    std.debug.print("usage: zig build peas -- doctor [project-directory] [--target <linux|macos|windows|web>] [--renderer <auto|gpu|opengl>] [--package <linux|macos|windows|web>]\n", .{});
    return error.InvalidArguments;
}

fn docsProject(allocator: std.mem.Allocator, args: *std.process.ArgIterator, mode: CliMode) !std.process.Child.Term {
    const topic = if (args.next()) |value| tools.parseDocsTopic(value) orelse return docsUsage() else .overview;
    if (args.next() != null) return docsUsage();
    const repository_root = std.process.getEnvVarOwned(allocator, "UP_REPOSITORY_ROOT") catch return error.DocsUnavailable;
    defer allocator.free(repository_root);
    var child = std.process.Child.init(&.{ "zig", "build", "docs" }, allocator);
    child.cwd = repository_root;
    child.stdin_behavior = if (mode.non_interactive) .Ignore else .Inherit;
    child.stdout_behavior = if (mode.json) .Ignore else .Inherit;
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

fn runZigBuild(allocator: std.mem.Allocator, arguments: []const []const u8, cwd: []const u8, mode: CliMode) !std.process.Child.Term {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = arguments,
        .cwd = cwd,
        .max_output_bytes = max_build_output_bytes,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!mode.json) try std.fs.File.stdout().writeAll(result.stdout);
    try std.fs.File.stderr().writeAll(result.stderr);
    if (!mode.json) {
        if (tools.diagnosticRemediation(tools.classifyDiagnostic(result.stderr))) |remediation| {
            if (result.stderr.len != 0 and result.stderr[result.stderr.len - 1] != '\n') try std.fs.File.stderr().writeAll("\n");
            std.debug.print("peas recovery: {s}\n", .{remediation});
        }
    }
    return result.term;
}

const JsonStatus = enum { ok, failed };

fn emitJson(allocator: std.mem.Allocator, command: ?tools.Command, status: JsonStatus, recovery: []const u8, mode: CliMode) !void {
    const document = try jsonDocument(allocator, command, status, recovery, mode);
    defer allocator.free(document);
    try std.fs.File.stdout().writeAll(document);
}

fn jsonDocument(allocator: std.mem.Allocator, command: ?tools.Command, status: JsonStatus, recovery: []const u8, mode: CliMode) ![]u8 {
    const command_name = if (command) |value| tools.commandName(value) else "";
    return std.fmt.allocPrint(allocator, "{{\"version\":1,\"command\":\"{s}\",\"status\":\"{s}\",\"recovery_code\":\"{s}\",\"non_interactive\":{s}}}\n", .{ command_name, @tagName(status), recovery, if (mode.non_interactive) "true" else "false" });
}

fn recoveryCode(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidArguments => "invalid_arguments",
        error.ProjectNotFound => "project_not_found",
        error.ProjectAssetsMissing => "project_assets_missing",
        error.UnsupportedTarget => "unsupported_target",
        error.WebBundleMissing => "web_bundle_missing",
        error.ReplayDiverged => "replay_diverged",
        error.NonInteractiveCommand => "interactive_command",
        error.TemplateUnavailable, error.PackageUnavailable, error.DocsUnavailable => "environment_unavailable",
        error.DiagnosticsBundleExists, error.DiagnosticsBundleTooLarge, error.InvalidDiagnosticsLimits => "diagnostics_limited",
        else => "operation_failed",
    };
}

fn recoveryExitCode(err: anyerror) u8 {
    return switch (err) {
        error.InvalidArguments => 64,
        error.NonInteractiveCommand => 65,
        error.ProjectNotFound => 20,
        error.ProjectAssetsMissing => 24,
        error.UnsupportedTarget => 22,
        else => 1,
    };
}

fn doctorRecoveryCode(code: u8) []const u8 {
    return switch (code) {
        @intFromEnum(DoctorCode.project) => "project_invalid",
        @intFromEnum(DoctorCode.zig) => "zig_unsupported",
        @intFromEnum(DoctorCode.target) => "target_unsupported",
        @intFromEnum(DoctorCode.renderer) => "renderer_unsupported",
        @intFromEnum(DoctorCode.assets) => "project_assets_missing",
        @intFromEnum(DoctorCode.browser_host) => "browser_host_unavailable",
        @intFromEnum(DoctorCode.package) => "package_prerequisites_unavailable",
        else => "operation_failed",
    };
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
    try std.testing.expectEqual(tools.Command.serve, tools.parseCommand("serve").?);
    try std.testing.expectEqual(tools.Command.support_bundle, tools.parseCommand("support-bundle").?);
    try std.testing.expectEqual(tools.Command.doctor, tools.parseCommand("doctor").?);
    try std.testing.expectEqual(tools.Command.docs, tools.parseCommand("docs").?);
}

test "known test selections parse" {
    try std.testing.expectEqual(tools.TestSelection.unit, tools.parseTestSelection("unit").?);
    try std.testing.expectEqual(tools.TestSelection.replay, tools.parseTestSelection("replay").?);
    try std.testing.expectEqual(tools.TestSelection.visual, tools.parseTestSelection("visual").?);
    try std.testing.expectEqual(tools.TestSelection.integration, tools.parseTestSelection("integration").?);
}

test "replay reproduction reports deterministic final-state divergence" {
    var value = try input_replay.parse(std.testing.allocator, "UPR1 60\n2 17\n1 2\n");
    defer value.deinit(std.testing.allocator);
    const first = try input_replay.reproduce(value);
    const second = try input_replay.reproduce(value);
    try std.testing.expectEqual(first.hash, second.hash);
    try std.testing.expectEqual(@as(usize, 3), first.frames);
    try std.testing.expectEqual(@as(u64, 3), first.updates);
    const match = try replayReport(std.testing.allocator, first, first.hash);
    defer std.testing.allocator.free(match);
    try std.testing.expect(std.mem.indexOf(u8, match, "divergence=none") != null);
    const mismatch = try replayReport(std.testing.allocator, first, first.hash +% 1);
    defer std.testing.allocator.free(mismatch);
    try std.testing.expect(std.mem.indexOf(u8, mismatch, "divergence=final-state") != null);
    var buffer: [18]u8 = undefined;
    const encoded = try std.fmt.bufPrint(&buffer, "0x{x}", .{first.hash});
    try std.testing.expectEqual(first.hash, try parseReplayHash(encoded));
}

test "project test classes report deterministic targets" {
    const cases = [_]struct { selection: tools.TestSelection, expected: []const u8 }{
        .{ .selection = .unit, .expected = "peas test: class=unit target=test artifacts=/tmp/game/zig-out\n" },
        .{ .selection = .replay, .expected = "peas test: class=replay target=test-replays artifacts=/tmp/game/zig-out\n" },
        .{ .selection = .visual, .expected = "peas test: class=visual target=test-scenes artifacts=/tmp/game/zig-out\n" },
        .{ .selection = .integration, .expected = "peas test: class=integration target=test-modules artifacts=/tmp/game/zig-out\n" },
    };
    for (cases) |case| {
        const report = try testTargetReport(std.testing.allocator, case.selection, "/tmp/game");
        defer std.testing.allocator.free(report);
        try std.testing.expectEqualStrings(case.expected, report);
    }
}

test "run launches a standard project debug target without a descriptor" {
    const command = try debugRunArguments(std.testing.allocator, &.{ "--frames", "2" });
    defer std.testing.allocator.free(command);
    try std.testing.expectEqual(@as(usize, 7), command.len);
    try std.testing.expectEqualStrings("zig", command[0]);
    try std.testing.expectEqualStrings("build", command[1]);
    try std.testing.expectEqualStrings("-Doptimize=Debug", command[2]);
    try std.testing.expectEqualStrings("run", command[3]);
    try std.testing.expectEqualStrings("--", command[4]);
    try std.testing.expectEqualStrings("--frames", command[5]);
    try std.testing.expectEqualStrings("2", command[6]);
}

test "known package targets parse" {
    try std.testing.expectEqual(tools.PackageTarget.linux, tools.parsePackageTarget("linux").?);
    try std.testing.expectEqual(tools.PackageTarget.macos, tools.parsePackageTarget("macos").?);
    try std.testing.expectEqual(tools.PackageTarget.windows, tools.parsePackageTarget("windows").?);
    try std.testing.expectEqual(tools.PackageTarget.web, tools.parsePackageTarget("web").?);
}

test "known package games parse and unsupported names fail" {
    try std.testing.expectEqual(tools.PackageGame.bounce, tools.parsePackageGame("bounce").?);
    try std.testing.expectEqual(tools.PackageGame.topdown, tools.parsePackageGame("topdown").?);
    try std.testing.expectEqual(tools.PackageGame.puzzle, tools.parsePackageGame("puzzle").?);
    try std.testing.expect(tools.parsePackageGame("unknown") == null);
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

test "doctor exit codes are stable" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(DoctorCode.ok));
    try std.testing.expectEqual(@as(u8, 20), @intFromEnum(DoctorCode.project));
    try std.testing.expectEqual(@as(u8, 21), @intFromEnum(DoctorCode.zig));
    try std.testing.expectEqual(@as(u8, 22), @intFromEnum(DoctorCode.target));
    try std.testing.expectEqual(@as(u8, 23), @intFromEnum(DoctorCode.renderer));
    try std.testing.expectEqual(@as(u8, 24), @intFromEnum(DoctorCode.assets));
    try std.testing.expectEqual(@as(u8, 25), @intFromEnum(DoctorCode.browser_host));
    try std.testing.expectEqual(@as(u8, 26), @intFromEnum(DoctorCode.package));
}

test "JSON envelopes cover every peas command" {
    const commands = [_]tools.Command{ .new, .run, .check, .@"test", .replay, .package, .serve, .support_bundle, .doctor, .docs };
    for (commands) |command| {
        const document = try jsonDocument(std.testing.allocator, command, .ok, "ok", .{ .non_interactive = true });
        defer std.testing.allocator.free(document);
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, document, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("version").?.integer);
        try std.testing.expectEqualStrings(tools.commandName(command), parsed.value.object.get("command").?.string);
        try std.testing.expectEqualStrings("ok", parsed.value.object.get("status").?.string);
        try std.testing.expectEqualStrings("ok", parsed.value.object.get("recovery_code").?.string);
        try std.testing.expect(parsed.value.object.get("non_interactive").?.bool);
    }
}

test "JSON recovery labels are stable" {
    try std.testing.expectEqualStrings("invalid_arguments", recoveryCode(error.InvalidArguments));
    try std.testing.expectEqualStrings("project_not_found", recoveryCode(error.ProjectNotFound));
    try std.testing.expectEqualStrings("interactive_command", recoveryCode(error.NonInteractiveCommand));
    try std.testing.expectEqual(@as(u8, 64), recoveryExitCode(error.InvalidArguments));
    try std.testing.expectEqual(@as(u8, 65), recoveryExitCode(error.NonInteractiveCommand));
}

test "new command rejects invalid destinations" {
    try std.testing.expectError(error.InvalidDestination, starter.validateDestination(""));
}
