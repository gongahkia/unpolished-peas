const std = @import("std");
const builtin = @import("builtin");

const max_project_file_bytes = 1024 * 1024;

const ProjectManifest = struct {
    minimum_zig_version: []const u8,
};

pub const Command = enum {
    new,
    run,
    check,
    @"test",
    package,
};

pub const TestSelection = enum {
    unit,
    replay,
    visual,
    integration,

    pub fn buildStep(self: TestSelection) []const u8 {
        return switch (self) {
            .unit => "test",
            .replay => "test-replays",
            .visual => "test-scenes",
            .integration => "test-modules",
        };
    }
};

pub const PackageTarget = enum {
    linux,
    macos,

    pub fn scriptName(self: PackageTarget) []const u8 {
        return switch (self) {
            .linux => "package_linux.sh",
            .macos => "package_macos.sh",
        };
    }
};

pub const CheckIssue = struct {
    path: []u8,
    line: usize,
    column: usize,
    message: []u8,

    pub fn deinit(self: *CheckIssue, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.message);
        self.* = undefined;
    }
};

pub fn parseCommand(value: []const u8) ?Command {
    return std.meta.stringToEnum(Command, value);
}

pub fn parseTestSelection(value: []const u8) ?TestSelection {
    return std.meta.stringToEnum(TestSelection, value);
}

pub fn parsePackageTarget(value: []const u8) ?PackageTarget {
    return std.meta.stringToEnum(PackageTarget, value);
}

pub fn printHelp() void {
    std.debug.print(
        \\usage: zig build peas -- <command> [args]
        \\commands: new run check test package
        \\check: zig build peas -- check [project-directory]
        \\run: zig build peas -- run [project-directory] -- [game-args]
        \\test: zig build peas -- test <unit|replay|visual|integration> [project-directory]
        \\package: zig build peas -- package <linux|macos> [output-directory]
        \\use `zig build peas -- help` for this message
        \\ 
    , .{});
}

pub fn discoverProject(allocator: std.mem.Allocator, start_path: []const u8) ![]u8 {
    var current = try std.fs.cwd().realpathAlloc(allocator, start_path);
    errdefer allocator.free(current);
    while (true) {
        const build_path = try std.fs.path.join(allocator, &.{ current, "build.zig" });
        defer allocator.free(build_path);
        if (std.fs.cwd().access(build_path, .{})) |_| return current else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        const parent = std.fs.path.dirname(current) orelse return error.ProjectNotFound;
        if (std.mem.eql(u8, parent, current)) return error.ProjectNotFound;
        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }
}

pub fn validateProjectAssets(allocator: std.mem.Allocator, root: []const u8) !void {
    const assets_path = try std.fs.path.join(allocator, &.{ root, "assets" });
    defer allocator.free(assets_path);
    var assets = std.fs.cwd().openDir(assets_path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return error.ProjectAssetsMissing,
        else => return err,
    };
    assets.close();
}

pub fn checkProject(allocator: std.mem.Allocator, root: []const u8) !?CheckIssue {
    const manifest_path = try std.fs.path.join(allocator, &.{ root, "build.zig.zon" });
    defer allocator.free(manifest_path);
    const manifest_source = std.fs.cwd().readFileAllocOptions(allocator, manifest_path, max_project_file_bytes, null, .of(u8), 0) catch |err| switch (err) {
        error.FileNotFound => return try issue(allocator, manifest_path, 1, 1, "missing project manifest"),
        else => return err,
    };
    defer allocator.free(manifest_source);

    var diagnostics: std.zon.parse.Diagnostics = .{};
    defer diagnostics.deinit(allocator);
    const manifest = std.zon.parse.fromSlice(ProjectManifest, allocator, manifest_source, &diagnostics, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.ParseZon => return try zonIssue(allocator, manifest_path, &diagnostics),
        else => return err,
    };
    defer std.zon.parse.free(allocator, manifest);

    const version_location = fieldLocation(manifest_source, "minimum_zig_version");
    const minimum_version = std.SemanticVersion.parse(manifest.minimum_zig_version) catch
        return try issue(allocator, manifest_path, version_location.line, version_location.column, "minimum_zig_version is not a semantic version");
    const current_version = std.SemanticVersion.parse(builtin.zig_version_string) catch unreachable;
    if (current_version.order(minimum_version) == .lt) {
        return try issueFmt(
            allocator,
            manifest_path,
            version_location.line,
            version_location.column,
            "requires Zig {s}; current Zig is {s}",
            .{ manifest.minimum_zig_version, builtin.zig_version_string },
        );
    }

    if (try checkZigFile(allocator, root, "build.zig", "missing project build configuration")) |value| return value;
    if (try checkZigFile(allocator, root, "src/main.zig", "missing project source")) |value| return value;
    const assets_path = try std.fs.path.join(allocator, &.{ root, "assets" });
    defer allocator.free(assets_path);
    validateProjectAssets(allocator, root) catch |err| switch (err) {
        error.ProjectAssetsMissing => return try issue(allocator, assets_path, 1, 1, "missing project assets"),
        else => return err,
    };
    return null;
}

fn checkZigFile(allocator: std.mem.Allocator, root: []const u8, relative_path: []const u8, missing_message: []const u8) !?CheckIssue {
    const path = try std.fs.path.join(allocator, &.{ root, relative_path });
    defer allocator.free(path);
    const source = std.fs.cwd().readFileAllocOptions(allocator, path, max_project_file_bytes, null, .of(u8), 0) catch |err| switch (err) {
        error.FileNotFound => return try issue(allocator, path, 1, 1, missing_message),
        else => return err,
    };
    defer allocator.free(source);
    var ast = try std.zig.Ast.parse(allocator, source, .zig);
    defer ast.deinit(allocator);
    if (ast.errors.len == 0) return null;
    const parse_error = ast.errors[0];
    const location = ast.tokenLocation(ast.errorOffset(parse_error), parse_error.token);
    return try issue(allocator, path, location.line + 1, location.column + 1, "invalid Zig source");
}

fn zonIssue(allocator: std.mem.Allocator, path: []const u8, diagnostics: *const std.zon.parse.Diagnostics) !CheckIssue {
    var errors = diagnostics.iterateErrors();
    const parse_error = errors.next() orelse return issue(allocator, path, 1, 1, "invalid project manifest");
    const location = parse_error.getLocation(diagnostics);
    return issueFmt(allocator, path, location.line + 1, location.column + 1, "{f}", .{parse_error.fmtMessage(diagnostics)});
}

fn issue(allocator: std.mem.Allocator, path: []const u8, line: usize, column: usize, message: []const u8) !CheckIssue {
    return issueFmt(allocator, path, line, column, "{s}", .{message});
}

fn issueFmt(allocator: std.mem.Allocator, path: []const u8, line: usize, column: usize, comptime format: []const u8, args: anytype) !CheckIssue {
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    const message = try std.fmt.allocPrint(allocator, format, args);
    return .{ .path = owned_path, .line = line, .column = column, .message = message };
}

fn fieldLocation(source: []const u8, field: []const u8) struct { line: usize, column: usize } {
    const offset = std.mem.indexOf(u8, source, field) orelse return .{ .line = 1, .column = 1 };
    var line: usize = 1;
    var column: usize = 1;
    for (source[0..offset]) |byte| {
        if (byte == '\n') {
            line += 1;
            column = 1;
        } else {
            column += 1;
        }
    }
    return .{ .line = line, .column = column };
}

test "tools module parses CLI commands without runtime imports" {
    try std.testing.expectEqual(Command.new, parseCommand("new").?);
    try std.testing.expect(parseCommand("publish") == null);
    try std.testing.expectEqual(TestSelection.replay, parseTestSelection("replay").?);
    try std.testing.expect(parseTestSelection("load") == null);
    try std.testing.expectEqual(PackageTarget.linux, parsePackageTarget("linux").?);
    try std.testing.expect(parsePackageTarget("windows") == null);
}

test "tools discover a project above the selected directory" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.makePath("project/assets");
    try temp.dir.makePath("project/src/nested");
    try temp.dir.writeFile(.{ .sub_path = "project/build.zig", .data = "pub fn build(_: anytype) void {}\n" });
    const root = try temp.dir.realpathAlloc(std.testing.allocator, "project");
    defer std.testing.allocator.free(root);
    const nested = try std.fs.path.join(std.testing.allocator, &.{ root, "src", "nested" });
    defer std.testing.allocator.free(nested);
    const discovered = try discoverProject(std.testing.allocator, nested);
    defer std.testing.allocator.free(discovered);
    try std.testing.expectEqualStrings(root, discovered);
    try validateProjectAssets(std.testing.allocator, discovered);
}

test "tools reject projects without assets" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.makePath("project");
    try temp.dir.writeFile(.{ .sub_path = "project/build.zig", .data = "pub fn build(_: anytype) void {}\n" });
    const root = try temp.dir.realpathAlloc(std.testing.allocator, "project");
    defer std.testing.allocator.free(root);
    try std.testing.expectError(error.ProjectAssetsMissing, validateProjectAssets(std.testing.allocator, root));
}

test "tools validate project fixture matrix without runtime imports" {
    const cases = [_]struct { name: []const u8, path_suffix: ?[]const u8, message: ?[]const u8 }{
        .{ .name = "valid", .path_suffix = null, .message = null },
        .{ .name = "invalid-zon", .path_suffix = "build.zig.zon", .message = "expected" },
        .{ .name = "missing-minimum-zig", .path_suffix = "build.zig.zon", .message = "missing" },
        .{ .name = "unsupported-zig", .path_suffix = "build.zig.zon", .message = "requires Zig" },
        .{ .name = "invalid-build", .path_suffix = "build.zig", .message = "invalid Zig source" },
        .{ .name = "missing-main", .path_suffix = "src/main.zig", .message = "missing project source" },
        .{ .name = "invalid-main", .path_suffix = "src/main.zig", .message = "invalid Zig source" },
        .{ .name = "missing-assets", .path_suffix = "assets", .message = "missing project assets" },
        .{ .name = "asset-file", .path_suffix = "assets", .message = "missing project assets" },
    };
    for (cases) |case| {
        const fixture_path = try std.fs.path.join(std.testing.allocator, &.{ "fixtures", "peas-check", case.name });
        defer std.testing.allocator.free(fixture_path);
        const root = try std.fs.cwd().realpathAlloc(std.testing.allocator, fixture_path);
        defer std.testing.allocator.free(root);
        const result = try checkProject(std.testing.allocator, root);
        if (case.message) |expected_message| {
            var check_issue = result orelse return error.TestExpectedEqual;
            defer check_issue.deinit(std.testing.allocator);
            try std.testing.expect(check_issue.line > 0 and check_issue.column > 0);
            try std.testing.expect(std.mem.endsWith(u8, check_issue.path, case.path_suffix.?));
            try std.testing.expect(std.mem.indexOf(u8, check_issue.message, expected_message) != null);
        } else {
            try std.testing.expect(result == null);
        }
    }
}
