const std = @import("std");
const assets = @import("assets.zig");

pub const native_format = "unpolished-peas-assets";
pub const native_version: u32 = 1;

pub const Entry = struct {
    id: []const u8,
    path: []const u8,
    dependencies: []const []const u8 = &.{},
};

pub const FontEntry = struct {
    id: []const u8,
    path: []const u8,
    bitmap: bool = false,
    dependencies: []const []const u8 = &.{},
    pixel_height: u16 = 20,
    atlas_width: u32 = 512,
    atlas_height: u32 = 512,
    first_codepoint: u21 = 32,
    codepoint_count: u16 = 224,
    fallback_codepoint: ?u21 = '?',
};

pub const Source = struct {
    format: []const u8,
    version: u32,
    images: []const Entry,
    audio: []const Entry,
    fonts: []const FontEntry,
    atlases: []const Entry,
    shaders: []const Entry,

    pub fn deinit(self: *Source, allocator: std.mem.Allocator) void {
        std.zon.parse.free(allocator, self.*);
        self.* = undefined;
    }

    pub fn encode(self: Source, allocator: std.mem.Allocator) ![]u8 {
        var output = std.Io.Writer.Allocating.init(allocator);
        defer output.deinit();
        try std.zon.stringify.serialize(self, .{}, &output.writer);
        return allocator.dupe(u8, output.written());
    }
};

pub const Edge = struct {
    asset: []const u8,
    dependency: []const u8,
};

pub const Graph = struct {
    allocator: std.mem.Allocator,
    edges: []Edge,

    pub fn deinit(self: *Graph) void {
        for (self.edges) |edge| {
            self.allocator.free(edge.asset);
            self.allocator.free(edge.dependency);
        }
        self.allocator.free(self.edges);
        self.* = undefined;
    }
};

pub const BoundHandle = union(enum) {
    image: assets.ImageHandle,
    audio: assets.AudioHandle,
    font: assets.FontHandle,
    atlas: assets.AtlasHandle,
    shader: assets.ShaderAssetHandle,
};

pub const Bound = struct {
    id: []const u8,
    path: []const u8,
    dependencies: []const []const u8,
    handle: BoundHandle,
};

pub const Reload = struct {
    id: []const u8,
    event: assets.ReloadEvent,
};

pub const Loaded = struct {
    allocator: std.mem.Allocator,
    bindings: []Bound,
    reloads: std.ArrayListUnmanaged(Reload) = .{},

    pub fn deinit(self: *Loaded) void {
        for (self.bindings) |binding| {
            self.allocator.free(binding.id);
            self.allocator.free(binding.path);
            for (binding.dependencies) |dependency| self.allocator.free(dependency);
            self.allocator.free(binding.dependencies);
        }
        self.allocator.free(self.bindings);
        self.reloads.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn handle(self: Loaded, id: []const u8) ?BoundHandle {
        for (self.bindings) |binding| if (std.mem.eql(u8, binding.id, id)) return binding.handle;
        return null;
    }

    pub fn reloadChanged(self: *Loaded, store: *assets.AssetStore) ![]const Reload {
        self.reloads.clearRetainingCapacity();
        for (try store.reloadChanged()) |event| {
            const start = self.reloads.items.len;
            for (self.bindings) |*binding| {
                if (!std.mem.eql(u8, binding.path, event.path)) continue;
                if (event.status == .changed) refreshHandle(&binding.handle);
                _ = try self.appendAffected(event, binding.id, start);
                try self.appendDependents(event, binding.id, start);
            }
        }
        return self.reloads.items;
    }

    fn appendDependents(self: *Loaded, event: assets.ReloadEvent, changed_id: []const u8, start: usize) !void {
        for (self.bindings) |binding| {
            if (!declaresDependency(binding.dependencies, changed_id)) continue;
            if (try self.appendAffected(event, binding.id, start)) try self.appendDependents(event, binding.id, start);
        }
    }

    fn appendAffected(self: *Loaded, event: assets.ReloadEvent, id: []const u8, start: usize) !bool {
        for (self.reloads.items[start..]) |reload| if (std.mem.eql(u8, reload.id, id)) return false;
        try self.reloads.append(self.allocator, .{ .id = id, .event = event });
        return true;
    }
};

pub const Diagnostic = struct {
    line: usize = 1,
    column: usize = 1,
    message: []const u8 = "invalid asset catalog",
};

pub fn parse(allocator: std.mem.Allocator, source: []const u8, diagnostic: *Diagnostic) !Source {
    const zon_source = try allocator.dupeZ(u8, source);
    defer allocator.free(zon_source);
    var zon_diagnostics: std.zon.parse.Diagnostics = .{};
    defer zon_diagnostics.deinit(allocator);
    var catalog = std.zon.parse.fromSlice(Source, allocator, zon_source, &zon_diagnostics, .{ .ignore_unknown_fields = false }) catch |err| switch (err) {
        error.ParseZon => {
            var errors = zon_diagnostics.iterateErrors();
            if (errors.next()) |parse_error| {
                const location = parse_error.getLocation(&zon_diagnostics);
                diagnostic.* = .{ .line = location.line + 1, .column = location.column + 1 };
            }
            return err;
        },
        else => return err,
    };
    errdefer catalog.deinit(allocator);
    try validate(catalog, source, diagnostic);
    return catalog;
}

pub fn graph(allocator: std.mem.Allocator, catalog: Source) !Graph {
    var edges = std.ArrayListUnmanaged(Edge){};
    errdefer {
        for (edges.items) |edge| {
            allocator.free(edge.asset);
            allocator.free(edge.dependency);
        }
        edges.deinit(allocator);
    }
    inline for (.{ catalog.images, catalog.audio, catalog.fonts, catalog.atlases, catalog.shaders }) |entries| for (entries) |entry| {
        for (entry.dependencies) |dependency| try appendEdge(allocator, &edges, entry.id, dependency);
    };
    return .{ .allocator = allocator, .edges = try edges.toOwnedSlice(allocator) };
}

pub fn validateFiles(dir: std.fs.Dir, catalog: Source) !void {
    inline for (.{ catalog.images, catalog.audio, catalog.fonts, catalog.atlases, catalog.shaders }) |entries| for (entries) |entry| {
        try dir.access(entry.path, .{});
    };
}

pub fn load(allocator: std.mem.Allocator, store: *assets.AssetStore, catalog: Source) !Loaded {
    try validateFiles(store.dir, catalog);
    var bindings = std.ArrayListUnmanaged(Bound){};
    errdefer deinitBindings(allocator, &bindings);
    for (catalog.images) |entry| try appendBinding(allocator, &bindings, entry.id, entry.path, entry.dependencies, .{ .image = try store.loadImage(entry.path) });
    for (catalog.audio) |entry| try appendBinding(allocator, &bindings, entry.id, entry.path, entry.dependencies, .{ .audio = try store.loadSound(entry.path) });
    for (catalog.fonts) |entry| {
        const handle = if (entry.bitmap) try store.loadBitmapFont(entry.path) else try store.loadFontWithOptions(entry.path, .{ .pixel_height = entry.pixel_height, .atlas_width = entry.atlas_width, .atlas_height = entry.atlas_height, .first_codepoint = entry.first_codepoint, .codepoint_count = entry.codepoint_count, .fallback_codepoint = entry.fallback_codepoint });
        try appendBinding(allocator, &bindings, entry.id, entry.path, entry.dependencies, .{ .font = handle });
    }
    for (catalog.atlases) |entry| try appendBinding(allocator, &bindings, entry.id, entry.path, entry.dependencies, .{ .atlas = try store.loadAtlas(entry.path) });
    for (catalog.shaders) |entry| try appendBinding(allocator, &bindings, entry.id, entry.path, entry.dependencies, .{ .shader = try store.loadShader(entry.path) });
    return .{ .allocator = allocator, .bindings = try bindings.toOwnedSlice(allocator) };
}

fn appendBinding(allocator: std.mem.Allocator, bindings: *std.ArrayListUnmanaged(Bound), id: []const u8, path: []const u8, dependencies: []const []const u8, handle: BoundHandle) !void {
    const owned_id = try allocator.dupe(u8, id);
    errdefer allocator.free(owned_id);
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    const owned_dependencies = try allocator.alloc([]const u8, dependencies.len);
    var dependency_count: usize = 0;
    errdefer {
        for (owned_dependencies[0..dependency_count]) |dependency| allocator.free(dependency);
        allocator.free(owned_dependencies);
    }
    for (dependencies) |dependency| {
        owned_dependencies[dependency_count] = try allocator.dupe(u8, dependency);
        dependency_count += 1;
    }
    try bindings.append(allocator, .{ .id = owned_id, .path = owned_path, .dependencies = owned_dependencies, .handle = handle });
}

fn deinitBindings(allocator: std.mem.Allocator, bindings: *std.ArrayListUnmanaged(Bound)) void {
    for (bindings.items) |binding| {
        allocator.free(binding.id);
        allocator.free(binding.path);
        for (binding.dependencies) |dependency| allocator.free(dependency);
        allocator.free(binding.dependencies);
    }
    bindings.deinit(allocator);
}

fn declaresDependency(dependencies: []const []const u8, id: []const u8) bool {
    for (dependencies) |dependency| if (std.mem.eql(u8, dependency, id)) return true;
    return false;
}

fn refreshHandle(handle: *BoundHandle) void {
    switch (handle.*) {
        inline else => |*value| {
            value.generation +%= 1;
            if (value.generation == 0) value.generation = 1;
        },
    }
}

fn appendEdge(allocator: std.mem.Allocator, edges: *std.ArrayListUnmanaged(Edge), asset: []const u8, dependency: []const u8) !void {
    const owned_asset = try allocator.dupe(u8, asset);
    errdefer allocator.free(owned_asset);
    const owned_dependency = try allocator.dupe(u8, dependency);
    errdefer allocator.free(owned_dependency);
    try edges.append(allocator, .{ .asset = owned_asset, .dependency = owned_dependency });
}

fn validate(catalog: Source, source: []const u8, diagnostic: *Diagnostic) !void {
    if (!std.mem.eql(u8, catalog.format, native_format)) return fail(diagnostic, source, "format", "unsupported asset catalog format");
    if (catalog.version != native_version) return fail(diagnostic, source, "version", "unsupported asset catalog version");
    inline for (.{ catalog.images, catalog.audio, catalog.fonts, catalog.atlases, catalog.shaders }) |entries| for (entries) |entry| {
        if (entry.id.len == 0 or !safePath(entry.path)) return fail(diagnostic, source, "path", "asset id and path must be nonempty and safe");
        for (entry.dependencies) |dependency| if (!entryExists(catalog, dependency)) return fail(diagnostic, source, "dependencies", "asset dependency references an unknown id");
    };
    for (catalog.fonts) |entry| if (entry.pixel_height == 0 or entry.atlas_width == 0 or entry.atlas_height == 0 or entry.codepoint_count == 0) return fail(diagnostic, source, "fonts", "font load options must be nonzero");
    try validateUnique(catalog, source, diagnostic);
}

fn validateUnique(catalog: Source, source: []const u8, diagnostic: *Diagnostic) !void {
    var ids = std.StringHashMapUnmanaged(void){};
    defer ids.deinit(std.heap.page_allocator);
    var paths = std.StringHashMapUnmanaged(void){};
    defer paths.deinit(std.heap.page_allocator);
    inline for (.{ catalog.images, catalog.audio, catalog.fonts, catalog.atlases, catalog.shaders }) |entries| for (entries) |entry| {
        const id_entry = try ids.getOrPut(std.heap.page_allocator, entry.id);
        if (id_entry.found_existing) return fail(diagnostic, source, "id", "asset ids must be unique");
        const path_entry = try paths.getOrPut(std.heap.page_allocator, entry.path);
        if (path_entry.found_existing) return fail(diagnostic, source, "path", "asset paths must be unique");
    };
}

fn entryExists(catalog: Source, id: []const u8) bool {
    inline for (.{ catalog.images, catalog.audio, catalog.fonts, catalog.atlases, catalog.shaders }) |entries| for (entries) |entry| if (std.mem.eql(u8, entry.id, id)) return true;
    return false;
}

fn safePath(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return false;
    var components = std.mem.tokenizeAny(u8, path, "/\\");
    while (components.next()) |component| if (std.mem.eql(u8, component, "..")) return false;
    return true;
}

fn fail(diagnostic: *Diagnostic, source: []const u8, field: []const u8, message: []const u8) error{InvalidCatalog} {
    const offset = std.mem.indexOf(u8, source, field) orelse 0;
    var line: usize = 1;
    var column: usize = 1;
    for (source[0..offset]) |byte| {
        if (byte == '\n') {
            line += 1;
            column = 1;
        } else column += 1;
    }
    diagnostic.* = .{ .line = line, .column = column, .message = message };
    return error.InvalidCatalog;
}

test "asset catalog validates paths, dependencies, and handle bindings" {
    const source = try std.fs.cwd().readFileAlloc(std.testing.allocator, "fixtures/catalogs/demo.upassets", 64 * 1024);
    defer std.testing.allocator.free(source);
    var diagnostic = Diagnostic{};
    var catalog = try parse(std.testing.allocator, source, &diagnostic);
    defer catalog.deinit(std.testing.allocator);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const names = [_][]const u8{ "ball.png", "blip.wav", "font.ttf", "atlas.json" };
    const sources = [_][]const u8{ "examples/assets/ball.png", "examples/assets/blip.wav", "examples/assets/fonts/Basic-Regular.ttf", "examples/assets/atlas.json" };
    for (names, sources) |name, fixture| {
        const bytes = try std.fs.cwd().readFileAlloc(std.testing.allocator, fixture, 8 * 1024 * 1024);
        defer std.testing.allocator.free(bytes);
        try tmp.dir.writeFile(.{ .sub_path = name, .data = bytes });
    }
    try tmp.dir.writeFile(.{ .sub_path = "effect.upshader", .data = "effect=passthrough\n" });
    var store = assets.AssetStore.init(std.testing.allocator, tmp.dir);
    defer store.deinit();
    var loaded = try load(std.testing.allocator, &store, catalog);
    defer loaded.deinit();
    const ball = loaded.handle("ball").?;
    const blip = loaded.handle("blip").?;
    const loaded_font = loaded.handle("font").?;
    const atlas = loaded.handle("atlas").?;
    const effect = loaded.handle("effect").?;
    try std.testing.expect((try store.tryImage(ball.image)).width > 0);
    try std.testing.expect((try store.trySound(blip.audio)).frames.len > 0);
    try std.testing.expect((try store.tryFont(loaded_font.font)).glyphs.len > 0);
    try std.testing.expect((try store.tryAtlas(atlas.atlas)).frames.len > 0);
    try std.testing.expect((try store.tryShader(effect.shader)).kind == .passthrough);
    var dependencies = try graph(std.testing.allocator, catalog);
    defer dependencies.deinit();
    try std.testing.expectEqual(@as(usize, 1), dependencies.edges.len);
    try std.testing.expectEqualStrings("atlas", dependencies.edges[0].asset);
    try std.testing.expectEqualStrings("ball", dependencies.edges[0].dependency);
}

test "asset catalog reloads changed declarations and reports affected identifiers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "a.upshader", .data = "effect=passthrough\n" });
    try tmp.dir.writeFile(.{ .sub_path = "b.upshader", .data = "effect=invert\n" });
    try tmp.dir.writeFile(.{ .sub_path = "untracked.txt", .data = "one" });
    const source =
        \\.{ .format = "unpolished-peas-assets", .version = 1, .images = .{}, .audio = .{}, .fonts = .{}, .atlases = .{}, .shaders = .{
        \\    .{ .id = "a", .path = "a.upshader" },
        \\    .{ .id = "b", .path = "b.upshader", .dependencies = .{ "a" } },
        \\} }
    ;
    var diagnostic = Diagnostic{};
    var catalog = try parse(std.testing.allocator, source, &diagnostic);
    defer catalog.deinit(std.testing.allocator);
    var store = assets.AssetStore.init(std.testing.allocator, tmp.dir);
    defer store.deinit();
    var loaded = try load(std.testing.allocator, &store, catalog);
    defer loaded.deinit();

    var stat = try tmp.dir.statFile("a.upshader");
    try tmp.dir.writeFile(.{ .sub_path = "a.upshader", .data = "effect=invert\n" });
    while ((try tmp.dir.statFile("a.upshader")).mtime == stat.mtime) {
        std.Thread.sleep(1_000_000);
        try tmp.dir.writeFile(.{ .sub_path = "a.upshader", .data = "effect=invert\n" });
        stat = try tmp.dir.statFile("a.upshader");
    }
    const reloads = try loaded.reloadChanged(&store);
    try std.testing.expectEqual(@as(usize, 2), reloads.len);
    try std.testing.expectEqualStrings("a", reloads[0].id);
    try std.testing.expectEqualStrings("b", reloads[1].id);
    try std.testing.expectEqual(assets.ReloadStatus.changed, reloads[0].event.status);
    try std.testing.expectEqualStrings("a.upshader", reloads[1].event.path);
    try std.testing.expectEqual(.invert, (try store.tryShader(loaded.handle("a").?.shader)).kind);

    _ = try store.loadText("untracked.txt");
    stat = try tmp.dir.statFile("untracked.txt");
    try tmp.dir.writeFile(.{ .sub_path = "untracked.txt", .data = "two" });
    while ((try tmp.dir.statFile("untracked.txt")).mtime == stat.mtime) {
        std.Thread.sleep(1_000_000);
        try tmp.dir.writeFile(.{ .sub_path = "untracked.txt", .data = "two" });
        stat = try tmp.dir.statFile("untracked.txt");
    }
    try std.testing.expectEqual(@as(usize, 0), (try loaded.reloadChanged(&store)).len);
}

test "asset catalog rejects duplicate unsafe and missing paths" {
    const duplicate =
        \\.{ .format = "unpolished-peas-assets", .version = 1, .images = .{ .{ .id = "a", .path = "same.png" }, .{ .id = "b", .path = "same.png" } }, .audio = .{}, .fonts = .{}, .atlases = .{}, .shaders = .{} }
        \\
    ;
    const unsafe =
        \\.{ .format = "unpolished-peas-assets", .version = 1, .images = .{ .{ .id = "a", .path = "../same.png" } }, .audio = .{}, .fonts = .{}, .atlases = .{}, .shaders = .{} }
        \\
    ;
    var diagnostic = Diagnostic{};
    try std.testing.expectError(error.InvalidCatalog, parse(std.testing.allocator, duplicate, &diagnostic));
    try std.testing.expect(diagnostic.line > 0 and diagnostic.column > 0);
    try std.testing.expectError(error.InvalidCatalog, parse(std.testing.allocator, unsafe, &diagnostic));
    var catalog = try parse(std.testing.allocator, ".{ .format = \"unpolished-peas-assets\", .version = 1, .images = .{ .{ .id = \"missing\", .path = \"missing.png\" } }, .audio = .{}, .fonts = .{}, .atlases = .{}, .shaders = .{} }", &diagnostic);
    defer catalog.deinit(std.testing.allocator);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectError(error.FileNotFound, validateFiles(tmp.dir, catalog));
}
