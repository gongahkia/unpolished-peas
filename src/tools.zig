const std = @import("std");
const builtin = @import("builtin");

const max_project_file_bytes = 1024 * 1024;
const supported_engine_version = "v0.0.3";

const ProjectManifest = struct {
    minimum_zig_version: []const u8,
    dependencies: ?struct {
        unpolished_peas: ?struct {
            url: ?[]const u8 = null,
        } = null,
    } = null,
};

pub const Command = enum {
    new,
    run,
    host,
    check,
    compile,
    migrate,
    @"test",
    replay,
    package,
    docs,
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

pub const HostMode = enum {
    dedicated,
    listen,
};

pub const HostRuntimeConfig = struct {
    mode: HostMode,
    bind_address: []const u8 = "127.0.0.1",
    port: u16 = 48081,
    max_peers: u16 = 16,
    ticks: u32 = 60,
};

pub const PackageTarget = enum {
    linux,
    macos,
    windows,

    pub fn scriptName(self: PackageTarget) []const u8 {
        return switch (self) {
            .linux => "package_linux.sh",
            .macos => "package_macos.sh",
            .windows => "package_windows.ps1",
        };
    }
};

pub const PackageGame = enum {
    bounce,
    topdown,
    platformer,
};

pub const CheckTarget = enum {
    linux,
    macos,
    windows,
};

pub const DocsTopic = enum {
    overview,
    quickstart,
    testing,
    api,

    pub fn relativePath(self: DocsTopic) []const u8 {
        return switch (self) {
            .overview => "index.md",
            .quickstart => "guides/quickstart.md",
            .testing => "guides/testing.md",
            .api => "api/core.md",
        };
    }
};

pub const DiagnosticContext = enum {
    none,
    missing_engine_module,
    missing_sdl_module,
    invalid_project_manifest,
    manual_sdl_linkage,
};

pub const CheckIssue = struct {
    kind: CheckIssueKind,
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

pub const CheckIssueKind = enum {
    missing_manifest,
    invalid_manifest,
    incompatible_zig,
    incompatible_engine,
    missing_build,
    invalid_build,
    missing_source,
    invalid_source,
    missing_assets,
};

pub fn parseCommand(value: []const u8) ?Command {
    return std.meta.stringToEnum(Command, value);
}

pub fn parseHostRuntimeConfig(arguments: []const []const u8) !HostRuntimeConfig {
    if (arguments.len == 0) return error.InvalidHostConfiguration;
    const mode_argument = arguments[0];
    var config = HostRuntimeConfig{ .mode = std.meta.stringToEnum(HostMode, mode_argument) orelse return error.InvalidHostConfiguration };
    var index: usize = 1;
    var bind_set = false;
    var port_set = false;
    var peers_set = false;
    var ticks_set = false;
    while (index < arguments.len) : (index += 2) {
        const value = if (index + 1 < arguments.len) arguments[index + 1] else return error.InvalidHostConfiguration;
        if (std.mem.eql(u8, arguments[index], "--bind")) {
            if (bind_set) return error.InvalidHostConfiguration;
            bind_set = true;
            config.bind_address = value;
        } else if (std.mem.eql(u8, arguments[index], "--port")) {
            if (port_set) return error.InvalidHostConfiguration;
            port_set = true;
            config.port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidHostConfiguration;
        } else if (std.mem.eql(u8, arguments[index], "--max-peers")) {
            if (peers_set) return error.InvalidHostConfiguration;
            peers_set = true;
            config.max_peers = std.fmt.parseInt(u16, value, 10) catch return error.InvalidHostConfiguration;
        } else if (std.mem.eql(u8, arguments[index], "--ticks")) {
            if (ticks_set) return error.InvalidHostConfiguration;
            ticks_set = true;
            config.ticks = std.fmt.parseInt(u32, value, 10) catch return error.InvalidHostConfiguration;
        } else return error.InvalidHostConfiguration;
    }
    if (config.max_peers == 0 or config.max_peers > 64 or config.ticks == 0 or config.ticks > 100_000) return error.InvalidHostConfiguration;
    _ = std.net.Address.parseIp(config.bind_address, config.port) catch return error.InvalidHostConfiguration;
    return config;
}

pub fn parseTestSelection(value: []const u8) ?TestSelection {
    return std.meta.stringToEnum(TestSelection, value);
}

pub fn parsePackageTarget(value: []const u8) ?PackageTarget {
    return std.meta.stringToEnum(PackageTarget, value);
}

pub fn parsePackageGame(value: []const u8) ?PackageGame {
    return std.meta.stringToEnum(PackageGame, value);
}

pub fn parseCheckTarget(value: []const u8) ?CheckTarget {
    return std.meta.stringToEnum(CheckTarget, value);
}

pub fn targetSetupDiagnostic(target: CheckTarget) ?[]const u8 {
    if (target != .windows) return null;
    if (builtin.os.tag != .windows) return "Windows validation must run on a Windows 10/11 x64 host";
    var compiler = std.DynLib.open("d3dcompiler_47.dll") catch return "D3DCompiler_47.dll is unavailable";
    compiler.close();
    return null;
}

pub fn parseDocsTopic(value: []const u8) ?DocsTopic {
    return std.meta.stringToEnum(DocsTopic, value);
}

pub fn classifyDiagnostic(text: []const u8) DiagnosticContext {
    if (std.mem.indexOf(u8, text, "no module named 'unpolished-peas-sdl3'")) |_| return .missing_sdl_module;
    if (std.mem.indexOf(u8, text, "no module named 'unpolished-peas'")) |_| return .missing_engine_module;
    if (std.mem.indexOf(u8, text, "build.zig.zon") != null and std.mem.indexOf(u8, text, "missing top-level") != null) return .invalid_project_manifest;
    if (std.mem.indexOf(u8, text, "unable to find dynamic system library 'SDL3'")) |_| return .manual_sdl_linkage;
    return .none;
}

pub fn diagnosticRemediation(context: DiagnosticContext) ?[]const u8 {
    return switch (context) {
        .none => null,
        .missing_engine_module => "add unpolished-peas to build.zig imports and declare it in build.zig.zon",
        .missing_sdl_module => "add unpolished-peas-sdl3 from the unpolished-peas dependency to build.zig imports",
        .invalid_project_manifest => "add the required build.zig.zon fields and use the engine's supported Zig version",
        .manual_sdl_linkage => "use the bundled unpolished-peas-sdl3 module instead of manually linking SDL3",
    };
}

pub fn printHelp() void {
    std.debug.print(
        \\usage: zig build peas -- <command> [args]
        \\commands: new run host check compile migrate test replay package docs
        \\check: zig build peas -- check [project-directory] [--target <linux|macos|windows>]
        \\compile: zig build peas -- compile [project-directory] [output-directory]
        \\migrate: zig build peas -- migrate <catalog|map> <input> <output>
        \\run: zig build peas -- run [project-directory] -- [game-args]
        \\host: zig build peas -- host <dedicated|listen> [--bind <ip>] [--port <u16>] [--max-peers <1..64>] [--ticks <1..100000>]
        \\test: zig build peas -- test <unit|replay|visual|integration> [project-directory]
        \\replay: zig build peas -- replay <fixture.upr> [expected-input-hash]
        \\package: zig build peas -- package <linux|macos|windows> [output-directory] [--game <bounce|topdown|platformer>]
        \\docs: zig build peas -- docs [overview|quickstart|testing|api]
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
    return validateProjectAssetRoot(allocator, root, "assets");
}

fn validateProjectAssetRoot(allocator: std.mem.Allocator, root: []const u8, asset_root: []const u8) !void {
    const assets_path = try std.fs.path.join(allocator, &.{ root, asset_root });
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
        error.FileNotFound => return try issue(allocator, .missing_manifest, manifest_path, 1, 1, "missing project manifest"),
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
        return try issue(allocator, .incompatible_zig, manifest_path, version_location.line, version_location.column, "minimum_zig_version is not a semantic version");
    const current_version = std.SemanticVersion.parse(builtin.zig_version_string) catch unreachable;
    if (current_version.order(minimum_version) == .lt) {
        return try issueFmt(
            allocator,
            .incompatible_zig,
            manifest_path,
            version_location.line,
            version_location.column,
            "requires Zig {s}; current Zig is {s}",
            .{ manifest.minimum_zig_version, builtin.zig_version_string },
        );
    }

    if (manifest.dependencies) |dependencies| if (dependencies.unpolished_peas) |engine| if (engine.url) |url| {
        if (std.mem.indexOf(u8, url, supported_engine_version) == null) {
            const engine_location = fieldLocation(manifest_source, "unpolished_peas");
            return try issueFmt(
                allocator,
                .incompatible_engine,
                manifest_path,
                engine_location.line,
                engine_location.column,
                "requires unpolished-peas {s}",
                .{supported_engine_version},
            );
        }
    };

    if (try checkZigFile(allocator, root, "build.zig", .missing_build, .invalid_build, "missing project build configuration")) |value| return value;
    if (try checkZigFile(allocator, root, "src/main.zig", .missing_source, .invalid_source, "missing project source")) |value| return value;
    return null;
}

fn checkZigFile(allocator: std.mem.Allocator, root: []const u8, relative_path: []const u8, missing_kind: CheckIssueKind, invalid_kind: CheckIssueKind, missing_message: []const u8) !?CheckIssue {
    const path = try std.fs.path.join(allocator, &.{ root, relative_path });
    defer allocator.free(path);
    const source = std.fs.cwd().readFileAllocOptions(allocator, path, max_project_file_bytes, null, .of(u8), 0) catch |err| switch (err) {
        error.FileNotFound => return try issue(allocator, missing_kind, path, 1, 1, missing_message),
        else => return err,
    };
    defer allocator.free(source);
    var ast = try std.zig.Ast.parse(allocator, source, .zig);
    defer ast.deinit(allocator);
    if (ast.errors.len == 0) return null;
    const parse_error = ast.errors[0];
    const location = ast.tokenLocation(ast.errorOffset(parse_error), parse_error.token);
    return try issue(allocator, invalid_kind, path, location.line + 1, location.column + 1, "invalid Zig source");
}

fn zonIssue(allocator: std.mem.Allocator, path: []const u8, diagnostics: *const std.zon.parse.Diagnostics) !CheckIssue {
    var errors = diagnostics.iterateErrors();
    const parse_error = errors.next() orelse return issue(allocator, .invalid_manifest, path, 1, 1, "invalid project manifest");
    const location = parse_error.getLocation(diagnostics);
    return issueFmt(allocator, .invalid_manifest, path, location.line + 1, location.column + 1, "{f}", .{parse_error.fmtMessage(diagnostics)});
}

fn issue(allocator: std.mem.Allocator, kind: CheckIssueKind, path: []const u8, line: usize, column: usize, message: []const u8) !CheckIssue {
    return issueFmt(allocator, kind, path, line, column, "{s}", .{message});
}

fn issueFmt(allocator: std.mem.Allocator, kind: CheckIssueKind, path: []const u8, line: usize, column: usize, comptime format: []const u8, args: anytype) !CheckIssue {
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    const message = try std.fmt.allocPrint(allocator, format, args);
    return .{ .kind = kind, .path = owned_path, .line = line, .column = column, .message = message };
}

fn fieldLocation(source: []const u8, field: []const u8) struct { line: usize, column: usize } {
    const offset = std.mem.indexOf(u8, source, field) orelse return .{ .line = 1, .column = 1 };
    var line: usize = 1;
    var column: usize = 1;
    for (source[0..offset]) |byte| {
        if (byte == '\n') {
            line += 1;
            column = 1;
        } else column += 1;
    }
    return .{ .line = line, .column = column };
}

test "tools module parses CLI commands without runtime imports" {
    try std.testing.expectEqual(Command.new, parseCommand("new").?);
    try std.testing.expectEqual(Command.replay, parseCommand("replay").?);
    try std.testing.expect(parseCommand("publish") == null);
    try std.testing.expectEqual(Command.docs, parseCommand("docs").?);
    try std.testing.expectEqual(Command.host, parseCommand("host").?);
    try std.testing.expectEqual(TestSelection.replay, parseTestSelection("replay").?);
    try std.testing.expect(parseTestSelection("load") == null);
    try std.testing.expectEqual(PackageTarget.linux, parsePackageTarget("linux").?);
    try std.testing.expectEqual(PackageTarget.windows, parsePackageTarget("windows").?);
    try std.testing.expectEqual(CheckTarget.windows, parseCheckTarget("windows").?);
    try std.testing.expect(parseCheckTarget("web") == null);
    try std.testing.expectEqual(DocsTopic.api, parseDocsTopic("api").?);
    try std.testing.expect(parseDocsTopic("reference") == null);
}

test "host configuration validates mode, endpoint, and bounded limits" {
    const config = try parseHostRuntimeConfig(&.{ "dedicated", "--bind", "127.0.0.1", "--port", "48081", "--max-peers", "16", "--ticks", "60" });
    try std.testing.expectEqual(HostMode.dedicated, config.mode);
    try std.testing.expectEqual(@as(u16, 16), config.max_peers);
    try std.testing.expectError(error.InvalidHostConfiguration, parseHostRuntimeConfig(&.{ "listen", "--max-peers", "65" }));
    try std.testing.expectError(error.InvalidHostConfiguration, parseHostRuntimeConfig(&.{ "listen", "--bind", "not-an-ip" }));
    try std.testing.expectError(error.InvalidHostConfiguration, parseHostRuntimeConfig(&.{ "listen", "--ticks", "0" }));
}

test "tools diagnose unsupported Windows setup" {
    const diagnostic = targetSetupDiagnostic(.windows);
    if (builtin.os.tag == .windows) {
        if (diagnostic) |value| try std.testing.expectEqualStrings("D3DCompiler_47.dll is unavailable", value);
    } else try std.testing.expectEqualStrings("Windows validation must run on a Windows 10/11 x64 host", diagnostic.?);
}

test "tools classify diagnostic fixtures" {
    const cases = [_]struct { path: []const u8, context: DiagnosticContext }{
        .{ .path = "fixtures/peas-diagnostics/missing-engine-module.txt", .context = .missing_engine_module },
        .{ .path = "fixtures/peas-diagnostics/missing-sdl-module.txt", .context = .missing_sdl_module },
        .{ .path = "fixtures/peas-diagnostics/invalid-manifest.txt", .context = .invalid_project_manifest },
        .{ .path = "fixtures/peas-diagnostics/manual-sdl-linkage.txt", .context = .manual_sdl_linkage },
        .{ .path = "fixtures/peas-diagnostics/unclassified.txt", .context = .none },
    };
    for (cases) |case| {
        const text = try std.fs.cwd().readFileAlloc(std.testing.allocator, case.path, 4096);
        defer std.testing.allocator.free(text);
        try std.testing.expectEqual(case.context, classifyDiagnostic(text));
        if (case.context == .none) {
            try std.testing.expect(diagnosticRemediation(case.context) == null);
        } else {
            try std.testing.expect(diagnosticRemediation(case.context) != null);
        }
    }
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

test "tools discover a fixture from a nested external path without mutation" {
    const root = try std.fs.cwd().realpathAlloc(std.testing.allocator, "fixtures/peas-check/valid");
    defer std.testing.allocator.free(root);
    const nested = try std.fs.path.join(std.testing.allocator, &.{ root, "src" });
    defer std.testing.allocator.free(nested);
    const discovered = try discoverProject(std.testing.allocator, nested);
    defer std.testing.allocator.free(discovered);
    try std.testing.expectEqualStrings(root, discovered);
    const manifest_path = try std.fs.path.join(std.testing.allocator, &.{ root, "build.zig.zon" });
    defer std.testing.allocator.free(manifest_path);
    const before = try std.fs.cwd().readFileAlloc(std.testing.allocator, manifest_path, 4096);
    defer std.testing.allocator.free(before);
    const result = try checkProject(std.testing.allocator, root);
    try std.testing.expect(result == null);
    const after = try std.fs.cwd().readFileAlloc(std.testing.allocator, manifest_path, 4096);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
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
    const cases = [_]struct { name: []const u8, path_suffix: ?[]const u8, message: ?[]const u8, kind: ?CheckIssueKind }{
        .{ .name = "valid", .path_suffix = null, .message = null, .kind = null },
        .{ .name = "invalid-zon", .path_suffix = "build.zig.zon", .message = "expected", .kind = .invalid_manifest },
        .{ .name = "missing-minimum-zig", .path_suffix = "build.zig.zon", .message = "missing", .kind = .invalid_manifest },
        .{ .name = "unsupported-zig", .path_suffix = "build.zig.zon", .message = "requires Zig", .kind = .incompatible_zig },
        .{ .name = "unsupported-engine", .path_suffix = "build.zig.zon", .message = "requires unpolished-peas", .kind = .incompatible_engine },
        .{ .name = "missing-manifest", .path_suffix = "build.zig.zon", .message = "missing project manifest", .kind = .missing_manifest },
        .{ .name = "invalid-build", .path_suffix = "build.zig", .message = "invalid Zig source", .kind = .invalid_build },
        .{ .name = "missing-main", .path_suffix = "src/main.zig", .message = "missing project source", .kind = .missing_source },
        .{ .name = "invalid-main", .path_suffix = "src/main.zig", .message = "invalid Zig source", .kind = .invalid_source },
        .{ .name = "missing-assets", .path_suffix = "assets", .message = "missing project assets", .kind = .missing_assets },
        .{ .name = "asset-file", .path_suffix = "assets", .message = "missing project assets", .kind = .missing_assets },
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
            try std.testing.expectEqual(case.kind.?, check_issue.kind);
            try std.testing.expect(check_issue.line > 0 and check_issue.column > 0);
            try std.testing.expect(std.mem.endsWith(u8, check_issue.path, case.path_suffix.?));
            try std.testing.expect(std.mem.indexOf(u8, check_issue.message, expected_message) != null);
        } else {
            try std.testing.expect(result == null);
        }
    }
}
