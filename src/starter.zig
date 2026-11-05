const std = @import("std");
const tools = @import("unpolished-peas-tools");

pub const Mode = enum { local, release };

pub fn parseMode(argument: ?[]const u8) !Mode {
    const value = argument orelse return .local;
    if (std.mem.eql(u8, value, "--release")) return .release;
    return error.InvalidArguments;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const template_root = args.next() orelse return usage();
    const destination = args.next() orelse return usage();
    const mode = parseMode(args.next()) catch return usage();
    if (args.next() != null) return usage();

    try createProjectWithMode(allocator, template_root, destination, mode);
    std.debug.print("created unpolished-peas project: {s}\n", .{destination});
}

pub fn createProject(allocator: std.mem.Allocator, template_root: []const u8, destination: []const u8) !void {
    return createProjectWithMode(allocator, template_root, destination, .local);
}

pub fn createProjectWithMode(allocator: std.mem.Allocator, template_root: []const u8, destination: []const u8, mode: Mode) !void {
    try validateDestination(destination);
    if (std.fs.cwd().access(destination, .{})) |_| return error.DestinationExists else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    var source = try std.fs.openDirAbsolute(template_root, .{});
    defer source.close();
    const manifest = try source.readFileAllocOptions(allocator, "build.zig.zon", 64 * 1024, null, .of(u8), 0);
    defer allocator.free(manifest);
    // Verify release coordinates before creating any destination files. A
    // failed fetch or hash mismatch must not leave a seemingly usable game.
    if (mode == .release) try verifyRelease(allocator, manifest);

    const directory_name = std.mem.trimEnd(u8, destination, if (std.fs.path.sep == '\\') "/\\" else "/");
    if (std.fs.path.dirname(directory_name)) |parent| try std.fs.cwd().makePath(parent);
    std.fs.cwd().makeDir(directory_name) catch |err| switch (err) {
        error.PathAlreadyExists => return error.DestinationExists,
        else => return err,
    };
    errdefer std.fs.cwd().deleteTree(destination) catch {};
    var output = try std.fs.cwd().makeOpenPath(destination, .{});
    defer output.close();
    try output.makePath("src");
    try source.copyFile("build.zig", output, "build.zig", .{});
    if (mode == .local) {
        const engine_root = try source.realpathAlloc(allocator, "../..");
        defer allocator.free(engine_root);
        const project_root = try output.realpathAlloc(allocator, ".");
        defer allocator.free(project_root);
        const relative = try std.fs.path.relative(allocator, project_root, engine_root);
        defer allocator.free(relative);
        const generated = try localManifest(allocator, manifest, relative);
        defer allocator.free(generated);
        try output.writeFile(.{ .sub_path = "build.zig.zon", .data = generated });
    } else {
        try output.writeFile(.{ .sub_path = "build.zig.zon", .data = manifest });
    }
    try source.copyFile("README.md", output, "README.md", .{});
    try source.copyFile(".gitignore", output, ".gitignore", .{});
    try output.makePath("assets");
    try source.copyFile("assets/.gitkeep", output, "assets/.gitkeep", .{});
    try source.copyFile("assets/README.md", output, "assets/README.md", .{});
    try source.copyFile("src/game.zig", output, "src/game.zig", .{});
    try source.copyFile("src/pickup_sound.zig", output, "src/pickup_sound.zig", .{});
    try source.copyFile("src/main.zig", output, "src/main.zig", .{});
}

// Keep all template metadata (including version, fingerprint and paths),
// replacing only the dependency expression. Parse tokens instead of matching
// text so prepared release tables and comments are handled the same way.
fn localManifest(allocator: std.mem.Allocator, manifest: [:0]const u8, path: []const u8) ![]u8 {
    var ast = try std.zig.Ast.parse(allocator, manifest, .zon);
    defer ast.deinit(allocator);
    if (ast.errors.len != 0) return error.InvalidTemplateManifest;
    var buffer: [2]std.zig.Ast.Node.Index = undefined;
    const root = ast.fullStructInit(&buffer, ast.rootDecls()[0]) orelse return error.InvalidTemplateManifest;
    for (root.ast.fields) |field| {
        const first = ast.firstToken(field);
        if (!std.mem.eql(u8, ast.tokenSlice(first - 2), "dependencies")) continue;
        const start = ast.tokenStart(first);
        const end = ast.tokenStart(ast.lastToken(field)) + ast.tokenSlice(ast.lastToken(field)).len;
        const rewritten = try std.fmt.allocPrintSentinel(
            allocator,
            "{s}.{{ .unpolished_peas = .{{ .path = \"{f}\" }} }}{s}",
            .{ manifest[0..start], std.zig.fmtString(path), manifest[end..] },
            0,
        );
        defer allocator.free(rewritten);
        var generated = try std.zig.Ast.parse(allocator, rewritten, .zon);
        defer generated.deinit(allocator);
        if (generated.errors.len != 0) return error.InvalidTemplateManifest;
        return generated.renderAlloc(allocator);
    }
    return error.InvalidTemplateManifest;
}

const ReleaseManifest = struct {
    dependencies: struct {
        unpolished_peas: ?struct {
            url: ?[]const u8 = null,
            hash: ?[]const u8 = null,
            path: ?[]const u8 = null,
        } = null,
    },
};

fn verifyRelease(allocator: std.mem.Allocator, manifest: [:0]const u8) !void {
    const parsed = std.zon.parse.fromSlice(ReleaseManifest, allocator, manifest, null, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.ParseZon => return error.InvalidTemplateManifest,
        else => return err,
    };
    defer std.zon.parse.free(allocator, parsed);
    const dependency = parsed.dependencies.unpolished_peas orelse return error.ReleaseCoordinatesUnavailable;
    const url = dependency.url orelse return error.ReleaseCoordinatesUnavailable;
    const expected = dependency.hash orelse return error.ReleaseCoordinatesUnavailable;
    if (dependency.path != null or
        !(std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "http://")) or
        !std.mem.startsWith(u8, expected, "unpolished_peas-")) return error.InvalidReleaseCoordinates;

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "zig", "fetch", url },
        .max_output_bytes = 1024 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .Exited or result.term.Exited != 0) {
        try std.fs.File.stderr().writeAll(result.stderr);
        return error.ReleaseFetchFailed;
    }
    const actual = std.mem.trim(u8, result.stdout, " \r\n\t");
    if (!std.mem.eql(u8, expected, actual)) return error.ReleaseHashMismatch;
}

pub fn validateDestination(destination: []const u8) !void {
    const name = std.fs.path.basename(destination);
    if (destination.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidDestination;
}

fn usage() error{InvalidArguments} {
    std.debug.print("usage: zig build new -- <directory> [--release]\n", .{});
    return error.InvalidArguments;
}

test "starter creates a structured project and rejects invalid destinations" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const destination = try std.fs.path.join(std.testing.allocator, &.{ root, "game" });
    defer std.testing.allocator.free(destination);
    const template_root = try std.fs.cwd().realpathAlloc(std.testing.allocator, "templates/starter");
    defer std.testing.allocator.free(template_root);

    try createProject(std.testing.allocator, template_root, destination);
    var project = try std.fs.openDirAbsolute(destination, .{});
    defer project.close();
    try project.access("build.zig", .{});
    try project.access("build.zig.zon", .{});
    try project.access("src/game.zig", .{});
    try project.access("src/pickup_sound.zig", .{});
    try project.access("src/main.zig", .{});
    try project.access("assets/.gitkeep", .{});
    try project.access("assets/README.md", .{});
    const source = try project.readFileAlloc(std.testing.allocator, "src/main.zig", 8192);
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "const game = @import(\"game.zig\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "state: game.Game") != null);
    const game = try project.readFileAlloc(std.testing.allocator, "src/game.zig", 16 * 1024);
    defer std.testing.allocator.free(game);
    try std.testing.expect(std.mem.indexOf(u8, game, "up.core.DeterministicRng") != null);
    try std.testing.expect(std.mem.indexOf(u8, game, "*up.core.GameContext") != null);
    try std.testing.expect(std.mem.indexOf(u8, game, "ctx.save_data") != null);
    try std.testing.expect(std.mem.indexOf(u8, game, "pub const storage_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, game, "unpolished-peas-sdl3") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "sdl.playGame(Game)") != null);
    const manifest = try project.readFileAlloc(std.testing.allocator, "build.zig.zon", 4096);
    defer std.testing.allocator.free(manifest);
    const template_manifest = try std.fs.cwd().readFileAlloc(std.testing.allocator, "templates/starter/build.zig.zon", 4096);
    defer std.testing.allocator.free(template_manifest);
    try std.testing.expect(!std.mem.eql(u8, template_manifest, manifest));
    try std.testing.expect(std.mem.indexOf(u8, manifest, ".path =") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, ".url =") == null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"assets\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"maps\"") == null);
    const check_issue = try tools.checkProject(std.testing.allocator, destination);
    try std.testing.expect(check_issue == null);
    try std.testing.expectError(error.DestinationExists, createProject(std.testing.allocator, template_root, destination));
    try std.testing.expectError(error.InvalidDestination, createProject(std.testing.allocator, template_root, ""));
}

test "local generation replaces prepared coordinates and escapes paths" {
    const template: [:0]const u8 =
        \\.{ .version = "1.2.3", .dependencies = .{
        \\    .unpolished_peas = .{ .url = "https://example.invalid/release.tar.gz", .hash = "unused" },
        \\}, .paths = .{ "src" } }
    ;
    const generated = try localManifest(std.testing.allocator, template, "../engine with spaces/quote\"/back\\slash");
    defer std.testing.allocator.free(generated);
    try std.testing.expect(std.mem.indexOf(u8, generated, "example.invalid") == null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "1.2.3") != null);
    const Parsed = struct { dependencies: struct { unpolished_peas: struct { path: []const u8 } } };
    const terminated = try std.testing.allocator.dupeZ(u8, generated);
    defer std.testing.allocator.free(terminated);
    const parsed = try std.zon.parse.fromSlice(Parsed, std.testing.allocator, terminated, null, .{ .ignore_unknown_fields = true });
    defer std.zon.parse.free(std.testing.allocator, parsed);
    try std.testing.expectEqualStrings("../engine with spaces/quote\"/back\\slash", parsed.dependencies.unpolished_peas.path);
}

test "release generation requires complete archive coordinates" {
    try std.testing.expectEqual(Mode.local, try parseMode(null));
    try std.testing.expectEqual(Mode.release, try parseMode("--release"));
    try std.testing.expectError(error.InvalidArguments, parseMode("--unknown"));
    try std.testing.expectError(error.ReleaseCoordinatesUnavailable, verifyRelease(std.testing.allocator, ".{ .dependencies = .{} }"));
    try std.testing.expectError(error.ReleaseCoordinatesUnavailable, verifyRelease(std.testing.allocator, ".{ .dependencies = .{ .unpolished_peas = .{ .url = \"https://example.invalid/release.tar.gz\" } } }"));
    try std.testing.expectError(error.InvalidReleaseCoordinates, verifyRelease(std.testing.allocator, ".{ .dependencies = .{ .unpolished_peas = .{ .path = \"../engine\", .url = \"--help\", .hash = \"unused\" } } }"));
}
