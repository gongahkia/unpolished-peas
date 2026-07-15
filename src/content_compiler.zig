const std = @import("std");
const catalog = @import("asset_catalog.zig");
const cache = @import("content_cache.zig");
const map_source = @import("map_source.zig");

pub const migration = @import("content_migration.zig");

const max_source_bytes = 64 * 1024 * 1024;
const state_format = "unpolished-peas-content-state";
const state_version: u32 = 1;

const Kind = enum { catalog, map };

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
    var inputs = try discoverInputs(allocator, project_root);
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

fn discoverInputs(allocator: std.mem.Allocator, project_root: []const u8) !std.ArrayListUnmanaged(Input) {
    var inputs = std.ArrayListUnmanaged(Input){};
    errdefer deinitInputs(allocator, &inputs);
    try appendDirectoryInputs(allocator, project_root, "assets", ".upassets", .catalog, &inputs);
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
        .catalog => .catalog,
        .map => .map,
    };
}

fn setDiagnostic(allocator: std.mem.Allocator, diagnostic: *Diagnostic, path: []const u8, line: usize, column: usize, message: []const u8) !void {
    if (diagnostic.path) |previous| allocator.free(previous);
    diagnostic.* = .{ .path = try allocator.dupe(u8, path), .line = line, .column = column, .message = message };
}

test "content compiler reuses unchanged catalog and map artifacts" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.makePath("project/assets");
    try temp.dir.makePath("project/maps");
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
    try std.testing.expectEqual(@as(usize, 2), initial.compiled);
    const repeated = try compileProject(std.testing.allocator, project_root, output_root, &diagnostic);
    try std.testing.expectEqual(@as(usize, 2), repeated.reused);
    const map_cache_path = try std.fs.path.join(std.testing.allocator, &.{ output_root, "maps", "main.upmap.upc" });
    defer std.testing.allocator.free(map_cache_path);
    const map_cache_bytes = try std.fs.cwd().readFileAlloc(std.testing.allocator, map_cache_path, cache.max_payload_bytes + 20);
    defer std.testing.allocator.free(map_cache_bytes);
    var map_cache = try cache.decode(std.testing.allocator, map_cache_bytes);
    defer map_cache.deinit();
    var cached_map_diagnostic = map_source.Diagnostic{};
    var cached_map = try map_source.parse(std.testing.allocator, map_cache.payload, &cached_map_diagnostic);
    defer cached_map.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("main", cached_map.metadata.name);
    var corrupt_cache = try std.testing.allocator.dupe(u8, map_cache_bytes);
    defer std.testing.allocator.free(corrupt_cache);
    corrupt_cache[0] = 0;
    try std.fs.cwd().writeFile(.{ .sub_path = map_cache_path, .data = corrupt_cache });
    const repaired = try compileProject(std.testing.allocator, project_root, output_root, &diagnostic);
    try std.testing.expectEqual(@as(usize, 1), repaired.compiled);
    try std.testing.expectEqual(@as(usize, 1), repaired.reused);
    try temp.dir.writeFile(.{ .sub_path = "project/maps/main.upmap", .data =
        \\.{ .format = "unpolished-peas-map", .version = 1, .metadata = .{ .name = "changed", .projection = .orthogonal, .tile_width = 8, .tile_height = 8, .chunk_size = 8 }, .tilesets = .{}, .layers = .{} }
        \\
    });
    const changed = try compileProject(std.testing.allocator, project_root, output_root, &diagnostic);
    try std.testing.expectEqual(@as(usize, 1), changed.compiled);
    try std.testing.expectEqual(@as(usize, 1), changed.reused);
    try std.fs.cwd().access(map_cache_path, .{});
}

test "content compiler accepts only native asset declarations" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.makePath("project/assets");
    try temp.dir.writeFile(.{ .sub_path = "project/assets/catalog.upassets", .data =
        \\.{ .format = "unpolished-peas-assets", .version = 1, .images = .{}, .audio = .{}, .fonts = .{}, .atlases = .{}, .shaders = .{} }
        \\
    });
    try temp.dir.writeFile(.{ .sub_path = "project/assets/legacy.json", .data = "not a native declaration\n" });
    const project_root = try temp.dir.realpathAlloc(std.testing.allocator, "project");
    defer std.testing.allocator.free(project_root);
    const output_root = try std.fs.path.join(std.testing.allocator, &.{ project_root, "zig-out", "content" });
    defer std.testing.allocator.free(output_root);
    var diagnostic = Diagnostic{};
    defer diagnostic.deinit(std.testing.allocator);
    const report = try compileProject(std.testing.allocator, project_root, output_root, &diagnostic);
    try std.testing.expectEqual(@as(usize, 1), report.compiled);
    const legacy_cache = try std.fs.path.join(std.testing.allocator, &.{ output_root, "assets", "legacy.json.upc" });
    defer std.testing.allocator.free(legacy_cache);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(legacy_cache, .{}));
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
    try std.testing.expectEqual(@as(usize, 2), first.compiled);
    try std.testing.expectEqual(@as(usize, 0), first.reused);
    const map_cache = try std.fs.path.join(std.testing.allocator, &.{ output_root, "maps", "platformer.upmap.upc" });
    defer std.testing.allocator.free(map_cache);
    const assets_cache = try std.fs.path.join(std.testing.allocator, &.{ output_root, "assets", "platformer.upassets.upc" });
    defer std.testing.allocator.free(assets_cache);
    try std.fs.cwd().access(map_cache, .{});
    try std.fs.cwd().access(assets_cache, .{});
    const second = try compileProject(std.testing.allocator, project_root, output_root, &diagnostic);
    try std.testing.expectEqual(@as(usize, 0), second.compiled);
    try std.testing.expectEqual(@as(usize, 2), second.reused);
}

test "content compiler builds the native top-down fixture" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const project_root = try std.fs.cwd().realpathAlloc(std.testing.allocator, "fixtures/topdown-project");
    defer std.testing.allocator.free(project_root);
    const output_root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(output_root);
    var diagnostic = Diagnostic{};
    defer diagnostic.deinit(std.testing.allocator);
    const first = try compileProject(std.testing.allocator, project_root, output_root, &diagnostic);
    try std.testing.expectEqual(@as(usize, 2), first.compiled);
    const map_cache = try std.fs.path.join(std.testing.allocator, &.{ output_root, "maps", "topdown.upmap.upc" });
    defer std.testing.allocator.free(map_cache);
    const assets_cache = try std.fs.path.join(std.testing.allocator, &.{ output_root, "assets", "topdown.upassets.upc" });
    defer std.testing.allocator.free(assets_cache);
    try std.fs.cwd().access(map_cache, .{});
    try std.fs.cwd().access(assets_cache, .{});
    const second = try compileProject(std.testing.allocator, project_root, output_root, &diagnostic);
    try std.testing.expectEqual(@as(usize, 0), second.compiled);
    try std.testing.expectEqual(@as(usize, 2), second.reused);
}
