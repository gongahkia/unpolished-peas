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
    handle: BoundHandle,
};

pub const Loaded = struct {
    allocator: std.mem.Allocator,
    bindings: []Bound,

    pub fn deinit(self: *Loaded) void {
        for (self.bindings) |binding| self.allocator.free(binding.id);
        self.allocator.free(self.bindings);
        self.* = undefined;
    }

    pub fn handle(self: Loaded, id: []const u8) ?BoundHandle {
        for (self.bindings) |binding| if (std.mem.eql(u8, binding.id, id)) return binding.handle;
        return null;
    }
};

pub const Diagnostic = struct {
    line: usize = 1,
    column: usize = 1,
    message: []const u8 = "invalid asset catalog",
};

pub fn parse(allocator: std.mem.Allocator, source: []const u8, diagnostic: *Diagnostic) !Source {
    var zon_diagnostics: std.zon.parse.Diagnostics = .{};
    defer zon_diagnostics.deinit(allocator);
    var catalog = std.zon.parse.fromSlice(Source, allocator, source, &zon_diagnostics, .{ .ignore_unknown_fields = false }) catch |err| switch (err) {
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
    errdefer {
        for (bindings.items) |binding| allocator.free(binding.id);
        bindings.deinit(allocator);
    }
    for (catalog.images) |entry| try appendBinding(allocator, &bindings, entry.id, .{ .image = try store.loadImage(entry.path) });
    for (catalog.audio) |entry| try appendBinding(allocator, &bindings, entry.id, .{ .audio = try store.loadSound(entry.path) });
    for (catalog.fonts) |entry| {
        const handle = if (entry.bitmap) try store.loadBitmapFont(entry.path) else try store.loadFontWithOptions(entry.path, .{ .pixel_height = entry.pixel_height, .atlas_width = entry.atlas_width, .atlas_height = entry.atlas_height, .first_codepoint = entry.first_codepoint, .codepoint_count = entry.codepoint_count, .fallback_codepoint = entry.fallback_codepoint });
        try appendBinding(allocator, &bindings, entry.id, .{ .font = handle });
    }
    for (catalog.atlases) |entry| try appendBinding(allocator, &bindings, entry.id, .{ .atlas = try store.loadAtlas(entry.path) });
    for (catalog.shaders) |entry| try appendBinding(allocator, &bindings, entry.id, .{ .shader = try store.loadShader(entry.path) });
    return .{ .allocator = allocator, .bindings = try bindings.toOwnedSlice(allocator) };
}

fn appendBinding(allocator: std.mem.Allocator, bindings: *std.ArrayListUnmanaged(Bound), id: []const u8, handle: BoundHandle) !void {
    const owned_id = try allocator.dupe(u8, id);
    errdefer allocator.free(owned_id);
    try bindings.append(allocator, .{ .id = owned_id, .handle = handle });
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

test "asset catalog rejects duplicate unsafe and missing paths" {
    const duplicate =
        \\.{ .format = "unpolished-peas-assets", .version = 1, .images = &.{ .{ .id = "a", .path = "same.png" }, .{ .id = "b", .path = "same.png" } }, .audio = &.{}, .fonts = &.{}, .atlases = &.{}, .shaders = &.{} }
        \\
    ;
    const unsafe =
        \\.{ .format = "unpolished-peas-assets", .version = 1, .images = &.{ .{ .id = "a", .path = "../same.png" } }, .audio = &.{}, .fonts = &.{}, .atlases = &.{}, .shaders = &.{} }
        \\
    ;
    var diagnostic = Diagnostic{};
    try std.testing.expectError(error.InvalidCatalog, parse(std.testing.allocator, duplicate, &diagnostic));
    try std.testing.expect(diagnostic.line > 0 and diagnostic.column > 0);
    try std.testing.expectError(error.InvalidCatalog, parse(std.testing.allocator, unsafe, &diagnostic));
    var catalog = try parse(std.testing.allocator, ".{ .format = \"unpolished-peas-assets\", .version = 1, .images = &.{ .{ .id = \"missing\", .path = \"missing.png\" } }, .audio = &.{}, .fonts = &.{}, .atlases = &.{}, .shaders = &.{} }", &diagnostic);
    defer catalog.deinit(std.testing.allocator);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectError(error.FileNotFound, validateFiles(tmp.dir, catalog));
}
