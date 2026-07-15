const std = @import("std");
const cache = @import("content_cache.zig");
const compiler = @import("content_compiler.zig");
const ecs = @import("ecs.zig");
const scene_runtime = @import("scene_runtime.zig");

const max_cache_bytes = cache.max_payload_bytes + 20;

pub const Status = enum {
    unchanged,
    reloaded,
    failed,
};

pub const Event = struct {
    status: Status,
    report: compiler.Report = .{},
    err: ?anyerror = null,
};

const Entry = struct {
    path: []u8,
    mtime: i128,
    size: u64,
};

pub const Controller = struct {
    allocator: std.mem.Allocator,
    project_root: []u8,
    output_root: []u8,
    watched: []Entry,
    compiled_scene: []u8,
    diagnostic: compiler.Diagnostic = .{},

    pub fn init(allocator: std.mem.Allocator, project_root: []const u8, output_root: []const u8, diagnostic: *compiler.Diagnostic) !Controller {
        if (!std.fs.path.isAbsolute(project_root) or !std.fs.path.isAbsolute(output_root)) return error.ContentPathsMustBeAbsolute;
        const owned_project_root = try allocator.dupe(u8, project_root);
        errdefer allocator.free(owned_project_root);
        const owned_output_root = try allocator.dupe(u8, output_root);
        errdefer allocator.free(owned_output_root);
        _ = try compiler.compileProject(allocator, owned_project_root, owned_output_root, diagnostic);
        const compiled_scene = try loadEntryCache(allocator, owned_project_root, owned_output_root, diagnostic);
        errdefer allocator.free(compiled_scene);
        const watched = try snapshot(allocator, owned_project_root);
        return .{
            .allocator = allocator,
            .project_root = owned_project_root,
            .output_root = owned_output_root,
            .watched = watched,
            .compiled_scene = compiled_scene,
        };
    }

    pub fn deinit(self: *Controller) void {
        self.diagnostic.deinit(self.allocator);
        deinitEntries(self.allocator, self.watched);
        self.allocator.free(self.compiled_scene);
        self.allocator.free(self.output_root);
        self.allocator.free(self.project_root);
        self.* = undefined;
    }

    pub fn compiledScene(self: *const Controller) []const u8 {
        return self.compiled_scene;
    }

    pub fn lastDiagnostic(self: *const Controller) ?*const compiler.Diagnostic {
        return if (self.diagnostic.path == null) null else &self.diagnostic;
    }

    pub fn loadRuntime(self: *const Controller, world: *ecs.World, bindings: []const scene_runtime.Binding, diagnostic: *scene_runtime.Diagnostic) !scene_runtime.Runtime {
        return scene_runtime.loadCompiled(self.allocator, world, self.compiled_scene, bindings, diagnostic);
    }

    pub fn reloadIfChanged(self: *Controller) !Event {
        const next_watched = try snapshot(self.allocator, self.project_root);
        if (entriesEqual(self.watched, next_watched)) {
            deinitEntries(self.allocator, next_watched);
            return .{ .status = .unchanged };
        }

        var next_diagnostic: compiler.Diagnostic = .{};
        const report = compiler.compileProject(self.allocator, self.project_root, self.output_root, &next_diagnostic) catch |err| {
            self.replaceWatched(next_watched);
            self.replaceDiagnostic(&next_diagnostic);
            return .{ .status = .failed, .err = err };
        };
        const next_scene = loadEntryCache(self.allocator, self.project_root, self.output_root, &next_diagnostic) catch |err| {
            self.replaceWatched(next_watched);
            self.replaceDiagnostic(&next_diagnostic);
            return .{ .status = .failed, .err = err };
        };

        self.allocator.free(self.compiled_scene);
        self.compiled_scene = next_scene;
        self.replaceWatched(next_watched);
        self.replaceDiagnostic(&next_diagnostic);
        return .{ .status = .reloaded, .report = report };
    }

    fn replaceWatched(self: *Controller, next: []Entry) void {
        deinitEntries(self.allocator, self.watched);
        self.watched = next;
    }

    fn replaceDiagnostic(self: *Controller, next: *compiler.Diagnostic) void {
        self.diagnostic.deinit(self.allocator);
        self.diagnostic = next.*;
        next.* = .{};
    }
};

fn loadEntryCache(allocator: std.mem.Allocator, project_root: []const u8, output_root: []const u8, diagnostic: *compiler.Diagnostic) ![]u8 {
    const path = try compiler.entryArtifactPath(allocator, project_root, output_root, diagnostic);
    defer allocator.free(path);
    const bytes = std.fs.cwd().readFileAlloc(allocator, path, max_cache_bytes) catch |err| {
        try setCacheDiagnostic(allocator, diagnostic, path, "compiled scene cache is missing");
        return err;
    };
    errdefer allocator.free(bytes);
    var decoded = cache.decode(allocator, bytes) catch |err| {
        try setCacheDiagnostic(allocator, diagnostic, path, "compiled scene cache is invalid");
        return err;
    };
    defer decoded.deinit();
    if (decoded.kind != .scene) {
        try setCacheDiagnostic(allocator, diagnostic, path, "compiled content is not a scene");
        return error.InvalidCompiledScene;
    }
    return bytes;
}

fn setCacheDiagnostic(allocator: std.mem.Allocator, diagnostic: *compiler.Diagnostic, path: []const u8, message: []const u8) !void {
    diagnostic.deinit(allocator);
    diagnostic.* = .{ .path = try allocator.dupe(u8, path), .message = message };
}

fn snapshot(allocator: std.mem.Allocator, project_root: []const u8) ![]Entry {
    var dir = try std.fs.openDirAbsolute(project_root, .{ .iterate = true });
    defer dir.close();
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var entries = std.ArrayListUnmanaged(Entry){};
    errdefer {
        for (entries.items) |entry| allocator.free(entry.path);
        entries.deinit(allocator);
    }
    while (try walker.next()) |entry| {
        if (entry.kind != .file or ignoredPath(entry.path)) continue;
        const stat = try dir.statFile(entry.path);
        try entries.append(allocator, .{
            .path = try allocator.dupe(u8, entry.path),
            .mtime = stat.mtime,
            .size = stat.size,
        });
    }
    std.sort.pdq(Entry, entries.items, {}, lessThan);
    return entries.toOwnedSlice(allocator);
}

fn ignoredPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, ".git/") or
        std.mem.startsWith(u8, path, ".git\\") or
        std.mem.startsWith(u8, path, ".zig-cache/") or
        std.mem.startsWith(u8, path, ".zig-cache\\") or
        std.mem.startsWith(u8, path, "zig-out/") or
        std.mem.startsWith(u8, path, "zig-out\\");
}

fn lessThan(_: void, lhs: Entry, rhs: Entry) bool {
    return std.mem.order(u8, lhs.path, rhs.path) == .lt;
}

fn entriesEqual(lhs: []const Entry, rhs: []const Entry) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |left, right| {
        if (!std.mem.eql(u8, left.path, right.path) or left.mtime != right.mtime or left.size != right.size) return false;
    }
    return true;
}

fn deinitEntries(allocator: std.mem.Allocator, entries: []Entry) void {
    for (entries) |entry| allocator.free(entry.path);
    allocator.free(entries);
}

test "content reload retains the last valid compiled scene and source diagnostic" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try writeProject(&temp);
    const root = try temp.dir.realpathAlloc(std.testing.allocator, "project");
    defer std.testing.allocator.free(root);
    const output = try std.fs.path.join(std.testing.allocator, &.{ root, "zig-out", "content" });
    defer std.testing.allocator.free(output);

    var diagnostic: compiler.Diagnostic = .{};
    defer diagnostic.deinit(std.testing.allocator);
    var controller = try Controller.init(std.testing.allocator, root, output, &diagnostic);
    defer controller.deinit();
    const previous = try std.testing.allocator.dupe(u8, controller.compiledScene());
    defer std.testing.allocator.free(previous);
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    var runtime_diagnostic: scene_runtime.Diagnostic = .{};
    defer runtime_diagnostic.deinit(std.testing.allocator);
    var runtime = try controller.loadRuntime(&world, &.{}, &runtime_diagnostic);
    defer {
        runtime.unload() catch {};
        runtime.deinit();
    }
    try std.testing.expectEqualStrings("main", runtime.source.metadata.name);

    try temp.dir.writeFile(.{ .sub_path = "project/scenes/main.upscene", .data = ".{ .format = \"invalid\", .version = 1 }\n" });
    const failed = try controller.reloadIfChanged();
    try std.testing.expectEqual(Status.failed, failed.status);
    try std.testing.expectEqualStrings(previous, controller.compiledScene());
    const failure = controller.lastDiagnostic().?;
    try std.testing.expect(std.mem.endsWith(u8, failure.path.?, "scenes/main.upscene"));
    try std.testing.expect(failure.line > 0 and failure.column > 0);

    try temp.dir.writeFile(.{ .sub_path = "project/scenes/main.upscene", .data =
        \\.{ .format = "unpolished-peas-scene", .version = 1, .metadata = .{ .name = "updated", .tags = .{} }, .entities = .{} }
        \\
    });
    const reloaded = try controller.reloadIfChanged();
    try std.testing.expectEqual(Status.reloaded, reloaded.status);
    try std.testing.expect(!std.mem.eql(u8, previous, controller.compiledScene()));
}

test "content reload tracks transitive asset changes and refreshes caches" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try writeProject(&temp);
    const root = try temp.dir.realpathAlloc(std.testing.allocator, "project");
    defer std.testing.allocator.free(root);
    const output = try std.fs.path.join(std.testing.allocator, &.{ root, "zig-out", "content" });
    defer std.testing.allocator.free(output);

    var diagnostic: compiler.Diagnostic = .{};
    defer diagnostic.deinit(std.testing.allocator);
    var controller = try Controller.init(std.testing.allocator, root, output, &diagnostic);
    defer controller.deinit();
    try temp.dir.writeFile(.{ .sub_path = "project/assets/sprites/ball.txt", .data = "changed-asset" });
    const reloaded = try controller.reloadIfChanged();
    try std.testing.expectEqual(Status.reloaded, reloaded.status);
    try std.testing.expectEqual(@as(usize, 3), reloaded.report.reused);
    try std.testing.expect((try controller.reloadIfChanged()).status == .unchanged);
}

test "content reload ignores generated Windows paths" {
    try std.testing.expect(ignoredPath("zig-out\\content\\scenes\\main.upc"));
    try std.testing.expect(ignoredPath(".zig-cache\\o\\artifact"));
}

fn writeProject(temp: *std.testing.TmpDir) !void {
    try temp.dir.makePath("project/scenes");
    try temp.dir.makePath("project/assets/sprites");
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
    try temp.dir.writeFile(.{ .sub_path = "project/assets/sprites/ball.txt", .data = "initial" });
    try temp.dir.writeFile(.{ .sub_path = "project/maps/main.upmap", .data =
        \\.{ .format = "unpolished-peas-map", .version = 1, .metadata = .{ .name = "main", .projection = .orthogonal, .tile_width = 8, .tile_height = 8, .chunk_size = 8 }, .tilesets = .{}, .layers = .{} }
        \\
    });
}
