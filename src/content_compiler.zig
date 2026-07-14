const std = @import("std");
const catalog = @import("asset_catalog.zig");
const cache = @import("content_cache.zig");
const map_source = @import("map_source.zig");
const scene = @import("scene.zig");

pub const migration = @import("content_migration.zig");
pub const ldtk_importer = @import("ldtk_importer.zig");
pub const tiled_importer = @import("tiled_importer.zig");

const max_source_bytes = 64 * 1024 * 1024;
const state_format = "unpolished-peas-content-state";
const state_version: u32 = 1;

const ProjectManifest = struct {
    format: []const u8,
    version: u32,
    entry_scene: []const u8,
    build: struct {
        title: []const u8,
        width: u32,
        height: u32,
        scale: u32,
    },
    assets: struct {
        root: []const u8,
    },
    engine: struct {
        version: []const u8,
    },
};

const Project = struct {
    allocator: std.mem.Allocator,
    entry_scene: []u8,
    assets_root: []u8,

    fn deinit(self: *Project) void {
        self.allocator.free(self.entry_scene);
        self.allocator.free(self.assets_root);
        self.* = undefined;
    }
};

const Kind = enum { scene, catalog, map };

const Input = struct {
    kind: Kind,
    path: []u8,
};

const StateEntry = struct {
    path: []const u8,
    fingerprint: u64,
};

const State = struct {
    format: []const u8,
    version: u32,
    entries: []const StateEntry,
};

pub const Diagnostic = struct {
    path: ?[]u8 = null,
    line: usize = 1,
    column: usize = 1,
    message: []const u8 = "content compilation failed",

    pub fn deinit(self: *Diagnostic, allocator: std.mem.Allocator) void {
        if (self.path) |path| allocator.free(path);
        self.* = undefined;
    }
};

pub const Report = struct {
    compiled: usize = 0,
    reused: usize = 0,
};

pub fn compileProject(allocator: std.mem.Allocator, project_root: []const u8, output_root: []const u8, diagnostic: *Diagnostic) !Report {
    var project = try readProject(allocator, project_root, diagnostic);
    defer project.deinit();
    var inputs = try discoverInputs(allocator, project_root, project);
    defer deinitInputs(allocator, &inputs);
    try std.fs.cwd().makePath(output_root);
    var previous = try loadState(allocator, output_root);
    defer if (previous) |*state| std.zon.parse.free(allocator, state.*);
    var next_entries = std.ArrayListUnmanaged(StateEntry){};
    defer next_entries.deinit(allocator);
    var report = Report{};
    for (inputs.items) |input| {
        const source_path = try std.fs.path.join(allocator, &.{ project_root, input.path });
        defer allocator.free(source_path);
        const source = std.fs.cwd().readFileAlloc(allocator, source_path, max_source_bytes) catch |err| {
            try setDiagnostic(allocator, diagnostic, source_path, 1, 1, "unable to read content source");
            return err;
        };
        defer allocator.free(source);
        const fingerprint = std.hash.Wyhash.hash(0, source);
        try next_entries.append(allocator, .{ .path = input.path, .fingerprint = fingerprint });
        const output_path = try artifactPath(allocator, output_root, input.path);
        defer allocator.free(output_path);
        const reusable = previousFingerprint(previous, input.path) == fingerprint and cacheIsFresh(allocator, output_path, input.kind, fingerprint);
        if (reusable) {
            report.reused += 1;
            continue;
        }
        const artifact = try compileInput(allocator, input.kind, source_path, source, diagnostic);
        defer allocator.free(artifact);
        const output_dir = std.fs.path.dirname(output_path) orelse return error.InvalidOutputPath;
        try std.fs.cwd().makePath(output_dir);
        const binary_cache = try cache.encode(allocator, cacheKind(input.kind), fingerprint, artifact);
        defer allocator.free(binary_cache);
        try std.fs.cwd().writeFile(.{ .sub_path = output_path, .data = binary_cache });
        report.compiled += 1;
    }
    try writeState(allocator, output_root, next_entries.items);
    return report;
}

pub fn entryArtifactPath(allocator: std.mem.Allocator, project_root: []const u8, output_root: []const u8, diagnostic: *Diagnostic) ![]u8 {
    var project = try readProject(allocator, project_root, diagnostic);
    defer project.deinit();
    return artifactPath(allocator, output_root, project.entry_scene);
}

fn readProject(allocator: std.mem.Allocator, project_root: []const u8, diagnostic: *Diagnostic) !Project {
    const path = try std.fs.path.join(allocator, &.{ project_root, "project.up" });
    defer allocator.free(path);
    const source = std.fs.cwd().readFileAllocOptions(allocator, path, max_source_bytes, null, .of(u8), 0) catch |err| {
        try setDiagnostic(allocator, diagnostic, path, 1, 1, "missing project manifest");
        return err;
    };
    defer allocator.free(source);
    var diagnostics: std.zon.parse.Diagnostics = .{};
    defer diagnostics.deinit(allocator);
    const manifest = std.zon.parse.fromSlice(ProjectManifest, allocator, source, &diagnostics, .{ .ignore_unknown_fields = false }) catch |err| {
        const location = zonLocation(&diagnostics);
        try setDiagnostic(allocator, diagnostic, path, location.line, location.column, "invalid project manifest");
        return err;
    };
    defer std.zon.parse.free(allocator, manifest);
    if (!std.mem.eql(u8, manifest.format, "unpolished-peas-project") or manifest.version != 1) {
        try setDiagnostic(allocator, diagnostic, path, 1, 1, "unsupported project manifest");
        return error.ContentCompileFailed;
    }
    if (!safePath(manifest.entry_scene) or !std.mem.endsWith(u8, manifest.entry_scene, ".upscene")) {
        const location = fieldLocation(source, "entry_scene");
        try setDiagnostic(allocator, diagnostic, path, location.line, location.column, "entry_scene must be a safe .upscene path");
        return error.ContentCompileFailed;
    }
    if (!safePath(manifest.assets.root)) {
        const location = fieldLocation(source, "assets");
        try setDiagnostic(allocator, diagnostic, path, location.line, location.column, "assets.root must be a safe relative path");
        return error.ContentCompileFailed;
    }
    const entry_scene = try allocator.dupe(u8, manifest.entry_scene);
    errdefer allocator.free(entry_scene);
    const assets_root = try allocator.dupe(u8, manifest.assets.root);
    return .{ .allocator = allocator, .entry_scene = entry_scene, .assets_root = assets_root };
}

fn discoverInputs(allocator: std.mem.Allocator, project_root: []const u8, project: Project) !std.ArrayListUnmanaged(Input) {
    var inputs = std.ArrayListUnmanaged(Input){};
    errdefer deinitInputs(allocator, &inputs);
    try appendInput(allocator, &inputs, .scene, project.entry_scene);
    try appendDirectoryInputs(allocator, project_root, project.assets_root, ".upassets", .catalog, &inputs);
    try appendDirectoryInputs(allocator, project_root, "maps", ".upmap", .map, &inputs);
    return inputs;
}

fn appendDirectoryInputs(allocator: std.mem.Allocator, project_root: []const u8, relative_dir: []const u8, suffix: []const u8, kind: Kind, inputs: *std.ArrayListUnmanaged(Input)) !void {
    const path = try std.fs.path.join(allocator, &.{ project_root, relative_dir });
    defer allocator.free(path);
    var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close();
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, suffix)) continue;
        const relative = try std.fs.path.join(allocator, &.{ relative_dir, entry.path });
        defer allocator.free(relative);
        try appendInput(allocator, inputs, kind, relative);
    }
}

fn appendInput(allocator: std.mem.Allocator, inputs: *std.ArrayListUnmanaged(Input), kind: Kind, path: []const u8) !void {
    for (inputs.items) |existing| if (std.mem.eql(u8, existing.path, path)) return;
    try inputs.append(allocator, .{ .kind = kind, .path = try allocator.dupe(u8, path) });
}

fn deinitInputs(allocator: std.mem.Allocator, inputs: *std.ArrayListUnmanaged(Input)) void {
    for (inputs.items) |input| allocator.free(input.path);
    inputs.deinit(allocator);
}

fn compileInput(allocator: std.mem.Allocator, kind: Kind, path: []const u8, source: []const u8, diagnostic: *Diagnostic) ![]u8 {
    return switch (kind) {
        .scene => blk: {
            var inner = scene.Diagnostic{};
            var parsed = scene.parse(allocator, source, &inner) catch |err| {
                try setDiagnostic(allocator, diagnostic, path, inner.line, inner.column, inner.message);
                return err;
            };
            defer parsed.deinit(allocator);
            break :blk parsed.encode(allocator);
        },
        .catalog => blk: {
            var inner = catalog.Diagnostic{};
            var parsed = catalog.parse(allocator, source, &inner) catch |err| {
                try setDiagnostic(allocator, diagnostic, path, inner.line, inner.column, inner.message);
                return err;
            };
            defer parsed.deinit(allocator);
            break :blk parsed.encode(allocator);
        },
        .map => blk: {
            var inner = map_source.Diagnostic{};
            var parsed = map_source.parse(allocator, source, &inner) catch |err| {
                try setDiagnostic(allocator, diagnostic, path, inner.line, inner.column, inner.message);
                return err;
            };
            defer parsed.deinit(allocator);
            break :blk parsed.encode(allocator);
        },
    };
}

fn loadState(allocator: std.mem.Allocator, output_root: []const u8) !?State {
    const path = try std.fs.path.join(allocator, &.{ output_root, "content-state.up" });
    defer allocator.free(path);
    const source = std.fs.cwd().readFileAllocOptions(allocator, path, max_source_bytes, null, .of(u8), 0) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(source);
    var diagnostics: std.zon.parse.Diagnostics = .{};
    defer diagnostics.deinit(allocator);
    const state = std.zon.parse.fromSlice(State, allocator, source, &diagnostics, .{ .ignore_unknown_fields = false }) catch return null;
    if (!std.mem.eql(u8, state.format, state_format) or state.version != state_version) {
        std.zon.parse.free(allocator, state);
        return null;
    }
    return state;
}

fn writeState(allocator: std.mem.Allocator, output_root: []const u8, entries: []const StateEntry) !void {
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    try std.zon.stringify.serialize(State{ .format = state_format, .version = state_version, .entries = entries }, .{}, &output.writer);
    const path = try std.fs.path.join(allocator, &.{ output_root, "content-state.up" });
    defer allocator.free(path);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = output.written() });
}

fn previousFingerprint(state: ?State, path: []const u8) ?u64 {
    const value = state orelse return null;
    for (value.entries) |entry| if (std.mem.eql(u8, entry.path, path)) return entry.fingerprint;
    return null;
}

fn artifactPath(allocator: std.mem.Allocator, output_root: []const u8, input_path: []const u8) ![]u8 {
    const filename = try std.fmt.allocPrint(allocator, "{s}.upc", .{input_path});
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &.{ output_root, filename });
}

fn cacheIsFresh(allocator: std.mem.Allocator, path: []const u8, kind: Kind, fingerprint: u64) bool {
    const bytes = std.fs.cwd().readFileAlloc(allocator, path, cache.max_payload_bytes + 20) catch return false;
    defer allocator.free(bytes);
    var decoded = cache.decode(allocator, bytes) catch return false;
    defer decoded.deinit();
    return decoded.kind == cacheKind(kind) and decoded.fingerprint == fingerprint;
}

fn cacheKind(kind: Kind) cache.Kind {
    return switch (kind) {
        .scene => .scene,
        .catalog => .catalog,
        .map => .map,
    };
}

fn safePath(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return false;
    var components = std.mem.tokenizeAny(u8, path, "/\\");
    while (components.next()) |component| if (std.mem.eql(u8, component, "..")) return false;
    return true;
}

fn zonLocation(diagnostics: *const std.zon.parse.Diagnostics) struct { line: usize, column: usize } {
    var errors = diagnostics.iterateErrors();
    const parse_error = errors.next() orelse return .{ .line = 1, .column = 1 };
    const location = parse_error.getLocation(diagnostics);
    return .{ .line = location.line + 1, .column = location.column + 1 };
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

fn setDiagnostic(allocator: std.mem.Allocator, diagnostic: *Diagnostic, path: []const u8, line: usize, column: usize, message: []const u8) !void {
    if (diagnostic.path) |previous| allocator.free(previous);
    diagnostic.* = .{ .path = try allocator.dupe(u8, path), .line = line, .column = column, .message = message };
}

test "content compiler reuses unchanged scene catalog and map artifacts" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.makePath("project/scenes");
    try temp.dir.makePath("project/assets");
    try temp.dir.makePath("project/maps");
    try temp.dir.writeFile(.{ .sub_path = "project/project.up", .data =
        \\.{ .format = "unpolished-peas-project", .version = 1, .entry_scene = "scenes/main.upscene", .build = .{ .title = "test", .width = 8, .height = 8, .scale = 1 }, .assets = .{ .root = "assets" }, .engine = .{ .version = "v0.0.3" } }
        \\
    });
    try temp.dir.writeFile(.{ .sub_path = "project/scenes/main.upscene", .data =
        \\.{ .format = "unpolished-peas-scene", .version = 1, .metadata = .{ .name = "main", .tags = .{} }, .entities = .{} }
        \\
    });
    try temp.dir.writeFile(.{ .sub_path = "project/assets/catalog.upassets", .data =
        \\.{ .format = "unpolished-peas-assets", .version = 1, .images = .{}, .audio = .{}, .fonts = .{}, .atlases = .{}, .shaders = .{} }
        \\
    });
    try temp.dir.writeFile(.{ .sub_path = "project/maps/main.upmap", .data =
        \\.{ .format = "unpolished-peas-map", .version = 1, .metadata = .{ .name = "main", .projection = .orthogonal, .tile_width = 8, .tile_height = 8, .chunk_size = 8 }, .tilesets = .{}, .layers = .{} }
        \\
    });
    const project_root = try temp.dir.realpathAlloc(std.testing.allocator, "project");
    defer std.testing.allocator.free(project_root);
    const output_root = try std.fs.path.join(std.testing.allocator, &.{ project_root, "zig-out", "content" });
    defer std.testing.allocator.free(output_root);
    var diagnostic = Diagnostic{};
    defer diagnostic.deinit(std.testing.allocator);
    const initial = try compileProject(std.testing.allocator, project_root, output_root, &diagnostic);
    try std.testing.expectEqual(@as(usize, 3), initial.compiled);
    const repeated = try compileProject(std.testing.allocator, project_root, output_root, &diagnostic);
    try std.testing.expectEqual(@as(usize, 3), repeated.reused);
    const scene_cache_path = try std.fs.path.join(std.testing.allocator, &.{ output_root, "scenes", "main.upscene.upc" });
    defer std.testing.allocator.free(scene_cache_path);
    const scene_cache_bytes = try std.fs.cwd().readFileAlloc(std.testing.allocator, scene_cache_path, cache.max_payload_bytes + 20);
    defer std.testing.allocator.free(scene_cache_bytes);
    var scene_cache = try cache.decode(std.testing.allocator, scene_cache_bytes);
    defer scene_cache.deinit();
    var cached_scene_diagnostic = scene.Diagnostic{};
    var cached_scene = try scene.parse(std.testing.allocator, scene_cache.payload, &cached_scene_diagnostic);
    defer cached_scene.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("main", cached_scene.metadata.name);
    var corrupt_cache = try std.testing.allocator.dupe(u8, scene_cache_bytes);
    defer std.testing.allocator.free(corrupt_cache);
    corrupt_cache[0] = 0;
    try std.fs.cwd().writeFile(.{ .sub_path = scene_cache_path, .data = corrupt_cache });
    const repaired = try compileProject(std.testing.allocator, project_root, output_root, &diagnostic);
    try std.testing.expectEqual(@as(usize, 1), repaired.compiled);
    try std.testing.expectEqual(@as(usize, 2), repaired.reused);
    try temp.dir.writeFile(.{ .sub_path = "project/maps/main.upmap", .data =
        \\.{ .format = "unpolished-peas-map", .version = 1, .metadata = .{ .name = "changed", .projection = .orthogonal, .tile_width = 8, .tile_height = 8, .chunk_size = 8 }, .tilesets = .{}, .layers = .{} }
        \\
    });
    const changed = try compileProject(std.testing.allocator, project_root, output_root, &diagnostic);
    try std.testing.expectEqual(@as(usize, 1), changed.compiled);
    try std.testing.expectEqual(@as(usize, 2), changed.reused);
    try std.fs.cwd().access(scene_cache_path, .{});
}

test "content compiler preserves source diagnostics" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.makePath("project/scenes");
    try temp.dir.makePath("project/assets");
    try temp.dir.writeFile(.{ .sub_path = "project/project.up", .data =
        \\.{ .format = "unpolished-peas-project", .version = 1, .entry_scene = "scenes/main.upscene", .build = .{ .title = "test", .width = 8, .height = 8, .scale = 1 }, .assets = .{ .root = "assets" }, .engine = .{ .version = "v0.0.3" } }
        \\
    });
    try temp.dir.writeFile(.{ .sub_path = "project/scenes/main.upscene", .data =
        \\.{
        \\    .format = "unpolished-peas-scene",
        \\    .version = 1,
        \\    .metadata = .{ .name = "main", .tags = .{} },
        \\    .entities = .{ .{ .id = "player", .name = "Player", .components = .{}, .references = .{ .{ .name = "target", .target = "missing" } } } },
        \\}
        \\
    });
    const project_root = try temp.dir.realpathAlloc(std.testing.allocator, "project");
    defer std.testing.allocator.free(project_root);
    const output_root = try std.fs.path.join(std.testing.allocator, &.{ project_root, "zig-out", "content" });
    defer std.testing.allocator.free(output_root);
    var diagnostic = Diagnostic{};
    defer diagnostic.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidScene, compileProject(std.testing.allocator, project_root, output_root, &diagnostic));
    try std.testing.expect(diagnostic.path != null and std.mem.endsWith(u8, diagnostic.path.?, "scenes/main.upscene"));
    try std.testing.expect(diagnostic.line > 1 and diagnostic.column > 0);
    try std.testing.expectEqualStrings("reference targets an unknown entity", diagnostic.message);
}

test "content compiler accepts imported Tiled map source" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.makePath("project/scenes");
    try temp.dir.makePath("project/assets");
    try temp.dir.makePath("project/maps");
    try temp.dir.writeFile(.{ .sub_path = "project/project.up", .data =
        \\.{ .format = "unpolished-peas-project", .version = 1, .entry_scene = "scenes/main.upscene", .build = .{ .title = "test", .width = 8, .height = 8, .scale = 1 }, .assets = .{ .root = "assets" }, .engine = .{ .version = "v0.0.3" } }
        \\
    });
    try temp.dir.writeFile(.{ .sub_path = "project/scenes/main.upscene", .data =
        \\.{ .format = "unpolished-peas-scene", .version = 1, .metadata = .{ .name = "main", .tags = .{} }, .entities = .{} }
        \\
    });
    var import_diagnostic = tiled_importer.Diagnostic{};
    const imported = try tiled_importer.importFile(std.testing.allocator, "fixtures/tiled/v1/finite-embedded.tmj", &import_diagnostic);
    defer std.testing.allocator.free(imported);
    try temp.dir.writeFile(.{ .sub_path = "project/maps/imported.upmap", .data = imported });
    const project_root = try temp.dir.realpathAlloc(std.testing.allocator, "project");
    defer std.testing.allocator.free(project_root);
    const output_root = try std.fs.path.join(std.testing.allocator, &.{ project_root, "zig-out", "content" });
    defer std.testing.allocator.free(output_root);
    var diagnostic = Diagnostic{};
    defer diagnostic.deinit(std.testing.allocator);
    const report = try compileProject(std.testing.allocator, project_root, output_root, &diagnostic);
    try std.testing.expectEqual(@as(usize, 2), report.compiled);
    const map_cache_path = try std.fs.path.join(std.testing.allocator, &.{ output_root, "maps", "imported.upmap.upc" });
    defer std.testing.allocator.free(map_cache_path);
    try std.fs.cwd().access(map_cache_path, .{});
}

test "content compiler accepts imported LDtk map source" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.makePath("project/scenes");
    try temp.dir.makePath("project/assets");
    try temp.dir.makePath("project/maps");
    try temp.dir.writeFile(.{ .sub_path = "project/project.up", .data =
        \\.{ .format = "unpolished-peas-project", .version = 1, .entry_scene = "scenes/main.upscene", .build = .{ .title = "test", .width = 8, .height = 8, .scale = 1 }, .assets = .{ .root = "assets" }, .engine = .{ .version = "v0.0.3" } }
        \\
    });
    try temp.dir.writeFile(.{ .sub_path = "project/scenes/main.upscene", .data =
        \\.{ .format = "unpolished-peas-scene", .version = 1, .metadata = .{ .name = "main", .tags = .{} }, .entities = .{} }
        \\
    });
    var import_diagnostic = ldtk_importer.Diagnostic{};
    var imported = try ldtk_importer.importFile(std.testing.allocator, "fixtures/ldtk/v1/project.ldtk", &import_diagnostic);
    defer imported.deinit(std.testing.allocator);
    try temp.dir.writeFile(.{ .sub_path = "project/maps/Main.upmap", .data = imported.maps[0].source });
    try temp.dir.writeFile(.{ .sub_path = "project/maps/External.upmap", .data = imported.maps[1].source });
    const project_root = try temp.dir.realpathAlloc(std.testing.allocator, "project");
    defer std.testing.allocator.free(project_root);
    const output_root = try std.fs.path.join(std.testing.allocator, &.{ project_root, "zig-out", "content" });
    defer std.testing.allocator.free(output_root);
    var diagnostic = Diagnostic{};
    defer diagnostic.deinit(std.testing.allocator);
    const report = try compileProject(std.testing.allocator, project_root, output_root, &diagnostic);
    try std.testing.expectEqual(@as(usize, 3), report.compiled);
    const map_cache_path = try std.fs.path.join(std.testing.allocator, &.{ output_root, "maps", "Main.upmap.upc" });
    defer std.testing.allocator.free(map_cache_path);
    try std.fs.cwd().access(map_cache_path, .{});
    const external_cache_path = try std.fs.path.join(std.testing.allocator, &.{ output_root, "maps", "External.upmap.upc" });
    defer std.testing.allocator.free(external_cache_path);
    try std.fs.cwd().access(external_cache_path, .{});
}

test "content compiler builds the native platformer fixture" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const project_root = try std.fs.cwd().realpathAlloc(std.testing.allocator, "fixtures/platformer-project");
    defer std.testing.allocator.free(project_root);
    const output_root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(output_root);
    var diagnostic = Diagnostic{};
    defer diagnostic.deinit(std.testing.allocator);
    const first = try compileProject(std.testing.allocator, project_root, output_root, &diagnostic);
    try std.testing.expectEqual(@as(usize, 3), first.compiled);
    try std.testing.expectEqual(@as(usize, 0), first.reused);
    const scene_cache = try std.fs.path.join(std.testing.allocator, &.{ output_root, "scenes", "platformer.upscene.upc" });
    defer std.testing.allocator.free(scene_cache);
    const map_cache = try std.fs.path.join(std.testing.allocator, &.{ output_root, "maps", "platformer.upmap.upc" });
    defer std.testing.allocator.free(map_cache);
    const assets_cache = try std.fs.path.join(std.testing.allocator, &.{ output_root, "assets", "platformer.upassets.upc" });
    defer std.testing.allocator.free(assets_cache);
    try std.fs.cwd().access(scene_cache, .{});
    try std.fs.cwd().access(map_cache, .{});
    try std.fs.cwd().access(assets_cache, .{});
    const second = try compileProject(std.testing.allocator, project_root, output_root, &diagnostic);
    try std.testing.expectEqual(@as(usize, 0), second.compiled);
    try std.testing.expectEqual(@as(usize, 3), second.reused);
}
