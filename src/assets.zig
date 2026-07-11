const std = @import("std");
const atlas_mod = @import("atlas.zig");
const Atlas = atlas_mod.Atlas;
const Image = @import("image.zig").Image;
const TileMap = @import("tilemap.zig").TileMap;

pub const AssetFile = struct {
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    path: []u8,
    bytes: []u8,
    max_bytes: usize,
    mtime: i128,

    pub fn load(allocator: std.mem.Allocator, dir: std.fs.Dir, path: []const u8, max_bytes: usize) !AssetFile {
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);

        const stat = try dir.statFile(path);
        const bytes = try dir.readFileAlloc(allocator, path, max_bytes);
        return .{
            .allocator = allocator,
            .dir = dir,
            .path = owned_path,
            .bytes = bytes,
            .max_bytes = max_bytes,
            .mtime = stat.mtime,
        };
    }

    pub fn deinit(self: *AssetFile) void {
        self.allocator.free(self.bytes);
        self.allocator.free(self.path);
        self.* = undefined;
    }

    pub fn reloadIfChanged(self: *AssetFile) !bool {
        const stat = try self.dir.statFile(self.path);
        if (stat.mtime == self.mtime) return false;

        const next = try self.dir.readFileAlloc(self.allocator, self.path, self.max_bytes);
        self.allocator.free(self.bytes);
        self.bytes = next;
        self.mtime = stat.mtime;
        return true;
    }

    pub fn text(self: AssetFile) []const u8 {
        return self.bytes;
    }
};

pub const TextHandle = struct { index: usize, generation: u32 };
pub const ImageHandle = struct { index: usize, generation: u32 };
pub const AtlasHandle = struct { index: usize, generation: u32 };
pub const TileMapHandle = struct { index: usize, generation: u32 };

pub const TileMapAssetOptions = struct {
    overlay_path: ?[]const u8 = null,
};

pub const ReloadStatus = enum {
    changed,
    failed,
};

pub const ReloadEvent = struct {
    path: []const u8,
    status: ReloadStatus,
    err: ?anyerror = null,
};

const TextAsset = struct {
    file: AssetFile,
    generation: u32 = 1,

    fn deinit(self: *TextAsset) void {
        self.file.deinit();
    }
};

const ImageAsset = struct {
    file: AssetFile,
    image: Image,
    generation: u32 = 1,

    fn deinit(self: *ImageAsset) void {
        self.image.deinit();
        self.file.deinit();
    }
};

const AtlasAsset = struct {
    json_file: AssetFile,
    image_file: AssetFile,
    atlas: Atlas,
    generation: u32 = 1,

    fn deinit(self: *AtlasAsset) void {
        self.atlas.deinit();
        self.image_file.deinit();
        self.json_file.deinit();
    }
};

const TileMapAsset = struct {
    file: AssetFile,
    map: TileMap,
    dependencies: []AssetFile,
    images: []TileMapImage,
    overlay_path: ?[]u8 = null,
    generation: u32 = 1,

    fn deinit(self: *TileMapAsset) void {
        for (self.images) |*image| image.image.deinit();
        self.map.allocator.free(self.images);
        for (self.dependencies) |*dependency| dependency.deinit();
        self.map.allocator.free(self.dependencies);
        if (self.overlay_path) |path| self.map.allocator.free(path);
        self.map.deinit();
        self.file.deinit();
    }
};

const TileMapImage = struct {
    tileset: u16,
    tile_id: ?u32,
    image: Image,
};

fn nextGeneration(generation: u32) u32 {
    const next = generation +% 1;
    return if (next == 0) 1 else next;
}

pub const AssetStore = struct {
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    texts: std.ArrayListUnmanaged(TextAsset) = .{},
    images: std.ArrayListUnmanaged(ImageAsset) = .{},
    atlases: std.ArrayListUnmanaged(AtlasAsset) = .{},
    tile_maps: std.ArrayListUnmanaged(TileMapAsset) = .{},
    events: std.ArrayListUnmanaged(ReloadEvent) = .{},

    pub fn init(allocator: std.mem.Allocator, dir: std.fs.Dir) AssetStore {
        return .{ .allocator = allocator, .dir = dir };
    }

    pub fn deinit(self: *AssetStore) void {
        for (self.texts.items) |*asset| asset.deinit();
        for (self.images.items) |*asset| asset.deinit();
        for (self.atlases.items) |*asset| asset.deinit();
        for (self.tile_maps.items) |*asset| asset.deinit();
        self.texts.deinit(self.allocator);
        self.images.deinit(self.allocator);
        self.atlases.deinit(self.allocator);
        self.tile_maps.deinit(self.allocator);
        self.events.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn loadText(self: *AssetStore, path: []const u8) !TextHandle {
        const file = try AssetFile.load(self.allocator, self.dir, path, 1024 * 1024);
        errdefer {
            var cleanup = file;
            cleanup.deinit();
        }

        const index = self.texts.items.len;
        try self.texts.append(self.allocator, .{ .file = file });
        return .{ .index = index, .generation = 1 };
    }

    pub fn loadPng(self: *AssetStore, path: []const u8) !ImageHandle {
        const file = try AssetFile.load(self.allocator, self.dir, path, 32 * 1024 * 1024);
        errdefer {
            var cleanup = file;
            cleanup.deinit();
        }

        const decoded = try Image.decodePng(self.allocator, file.bytes);
        errdefer {
            var cleanup = decoded;
            cleanup.deinit();
        }

        const index = self.images.items.len;
        try self.images.append(self.allocator, .{ .file = file, .image = decoded });
        return .{ .index = index, .generation = 1 };
    }

    pub fn loadAtlas(self: *AssetStore, path: []const u8) !AtlasHandle {
        const json_file = try AssetFile.load(self.allocator, self.dir, path, 8 * 1024 * 1024);
        errdefer {
            var cleanup = json_file;
            cleanup.deinit();
        }
        const image_rel = try atlas_mod.imagePathFromJson(self.allocator, json_file.bytes);
        defer self.allocator.free(image_rel);
        const image_path = try atlas_mod.resolveSiblingPath(self.allocator, path, image_rel);
        defer self.allocator.free(image_path);
        const image_file = try AssetFile.load(self.allocator, self.dir, image_path, 32 * 1024 * 1024);
        errdefer {
            var cleanup = image_file;
            cleanup.deinit();
        }
        const decoded_atlas = try Atlas.decode(self.allocator, image_file.bytes, image_path, json_file.bytes);
        errdefer {
            var cleanup = decoded_atlas;
            cleanup.deinit();
        }

        const index = self.atlases.items.len;
        try self.atlases.append(self.allocator, .{ .json_file = json_file, .image_file = image_file, .atlas = decoded_atlas });
        return .{ .index = index, .generation = 1 };
    }

    pub fn loadTileMap(self: *AssetStore, path: []const u8) !TileMapHandle {
        return self.loadTileMapWithOptions(path, .{});
    }

    pub fn loadTileMapWithOptions(self: *AssetStore, path: []const u8, options: TileMapAssetOptions) !TileMapHandle {
        const asset = try self.loadTileMapAsset(path, options);
        errdefer {
            var cleanup = asset;
            cleanup.deinit();
        }
        const index = self.tile_maps.items.len;
        try self.tile_maps.append(self.allocator, asset);
        return .{ .index = index, .generation = 1 };
    }

    pub fn text(self: AssetStore, handle: TextHandle) []const u8 {
        return self.tryText(handle) catch @panic("stale text handle");
    }

    pub fn tryText(self: AssetStore, handle: TextHandle) ![]const u8 {
        if (handle.index >= self.texts.items.len or self.texts.items[handle.index].generation != handle.generation) return error.StaleHandle;
        return self.texts.items[handle.index].file.text();
    }

    pub fn image(self: AssetStore, handle: ImageHandle) Image {
        return self.tryImage(handle) catch @panic("stale image handle");
    }

    pub fn tryImage(self: AssetStore, handle: ImageHandle) !Image {
        if (handle.index >= self.images.items.len or self.images.items[handle.index].generation != handle.generation) return error.StaleHandle;
        return self.images.items[handle.index].image;
    }

    pub fn imagePtr(self: *AssetStore, handle: ImageHandle) *const Image {
        return self.tryImagePtr(handle) catch @panic("stale image handle");
    }

    pub fn tryImagePtr(self: *AssetStore, handle: ImageHandle) !*const Image {
        if (handle.index >= self.images.items.len or self.images.items[handle.index].generation != handle.generation) return error.StaleHandle;
        return &self.images.items[handle.index].image;
    }

    pub fn atlas(self: AssetStore, handle: AtlasHandle) Atlas {
        return self.tryAtlas(handle) catch @panic("stale atlas handle");
    }

    pub fn tryAtlas(self: AssetStore, handle: AtlasHandle) !Atlas {
        if (handle.index >= self.atlases.items.len or self.atlases.items[handle.index].generation != handle.generation) return error.StaleHandle;
        return self.atlases.items[handle.index].atlas;
    }

    pub fn atlasPtr(self: *AssetStore, handle: AtlasHandle) *const Atlas {
        return self.tryAtlasPtr(handle) catch @panic("stale atlas handle");
    }

    pub fn tryAtlasPtr(self: *AssetStore, handle: AtlasHandle) !*const Atlas {
        if (handle.index >= self.atlases.items.len or self.atlases.items[handle.index].generation != handle.generation) return error.StaleHandle;
        return &self.atlases.items[handle.index].atlas;
    }

    pub fn tileMap(self: AssetStore, handle: TileMapHandle) TileMap {
        return self.tryTileMap(handle) catch @panic("stale tile-map handle");
    }

    pub fn tryTileMap(self: AssetStore, handle: TileMapHandle) !TileMap {
        if (handle.index >= self.tile_maps.items.len or self.tile_maps.items[handle.index].generation != handle.generation) return error.StaleHandle;
        return self.tile_maps.items[handle.index].map;
    }

    pub fn tileMapPtr(self: *AssetStore, handle: TileMapHandle) *const TileMap {
        return self.tryTileMapPtr(handle) catch @panic("stale tile-map handle");
    }

    pub fn tryTileMapPtr(self: *AssetStore, handle: TileMapHandle) !*const TileMap {
        if (handle.index >= self.tile_maps.items.len or self.tile_maps.items[handle.index].generation != handle.generation) return error.StaleHandle;
        return &self.tile_maps.items[handle.index].map;
    }

    pub fn drawTileMap(self: *AssetStore, handle: TileMapHandle, camera: *const @import("camera.zig").Camera2D, canvas: *@import("canvas.zig").Canvas, time: f32) void {
        _ = self.tryTileMap(handle) catch @panic("stale tile-map handle");
        const asset = &self.tile_maps.items[handle.index];
        const Resolver = struct {
            images: []const TileMapImage,
            fn resolve(context: *const anyopaque, tileset: u16, tile_id: u32) ?Image {
                const self_resolver: *const @This() = @ptrCast(@alignCast(context));
                for (self_resolver.images) |entry| if (entry.tileset == tileset and (entry.tile_id == null or entry.tile_id.? == tile_id)) return entry.image;
                return null;
            }
        };
        const resolver = Resolver{ .images = asset.images };
        asset.map.drawResolvedImagesAt(.init(canvas, camera), .{ .context = &resolver, .resolve = Resolver.resolve }, time);
    }

    pub fn reloadChanged(self: *AssetStore) ![]const ReloadEvent {
        self.events.clearRetainingCapacity();

        for (self.texts.items) |*asset| {
            if (asset.file.reloadIfChanged() catch |err| {
                try self.events.append(self.allocator, .{ .path = asset.file.path, .status = .failed, .err = err });
                continue;
            }) {
                asset.generation +%= 1;
                if (asset.generation == 0) asset.generation = 1;
                try self.events.append(self.allocator, .{ .path = asset.file.path, .status = .changed });
            }
        }

        for (self.images.items) |*asset| {
            const stat = asset.file.dir.statFile(asset.file.path) catch |err| {
                try self.events.append(self.allocator, .{ .path = asset.file.path, .status = .failed, .err = err });
                continue;
            };
            if (stat.mtime == asset.file.mtime) continue;

            const bytes = asset.file.dir.readFileAlloc(self.allocator, asset.file.path, asset.file.max_bytes) catch |err| {
                try self.events.append(self.allocator, .{ .path = asset.file.path, .status = .failed, .err = err });
                continue;
            };

            const next = Image.decodePng(self.allocator, bytes) catch |err| {
                self.allocator.free(bytes);
                try self.events.append(self.allocator, .{ .path = asset.file.path, .status = .failed, .err = err });
                continue;
            };

            asset.image.deinit();
            self.allocator.free(asset.file.bytes);
            asset.file.bytes = bytes;
            asset.file.mtime = stat.mtime;
            asset.image = next;
            asset.generation +%= 1;
            if (asset.generation == 0) asset.generation = 1;
            try self.events.append(self.allocator, .{ .path = asset.file.path, .status = .changed });
        }

        for (self.atlases.items) |*asset| {
            if (self.reloadAtlas(asset) catch |err| {
                try self.events.append(self.allocator, .{ .path = asset.json_file.path, .status = .failed, .err = err });
                continue;
            }) {
                try self.events.append(self.allocator, .{ .path = asset.json_file.path, .status = .changed });
            }
        }

        for (self.tile_maps.items) |*asset| {
            if (self.reloadTileMap(asset) catch |err| {
                try self.events.append(self.allocator, .{ .path = asset.file.path, .status = .failed, .err = err });
                continue;
            }) {
                try self.events.append(self.allocator, .{ .path = asset.file.path, .status = .changed });
            }
        }

        return self.events.items;
    }

    fn reloadAtlas(self: *AssetStore, asset: *AtlasAsset) !bool {
        const json_stat = try asset.json_file.dir.statFile(asset.json_file.path);
        const image_stat = try asset.image_file.dir.statFile(asset.image_file.path);
        if (json_stat.mtime == asset.json_file.mtime and image_stat.mtime == asset.image_file.mtime) return false;

        const json_file = try AssetFile.load(self.allocator, self.dir, asset.json_file.path, asset.json_file.max_bytes);
        errdefer {
            var cleanup = json_file;
            cleanup.deinit();
        }
        const image_rel = try atlas_mod.imagePathFromJson(self.allocator, json_file.bytes);
        defer self.allocator.free(image_rel);
        const image_path = try atlas_mod.resolveSiblingPath(self.allocator, asset.json_file.path, image_rel);
        defer self.allocator.free(image_path);
        const image_file = try AssetFile.load(self.allocator, self.dir, image_path, asset.image_file.max_bytes);
        errdefer {
            var cleanup = image_file;
            cleanup.deinit();
        }
        const decoded_atlas = try Atlas.decode(self.allocator, image_file.bytes, image_path, json_file.bytes);
        errdefer {
            var cleanup = decoded_atlas;
            cleanup.deinit();
        }

        const generation = nextGeneration(asset.generation);
        asset.deinit();
        asset.* = .{ .json_file = json_file, .image_file = image_file, .atlas = decoded_atlas, .generation = generation };
        return true;
    }

    fn reloadTileMap(self: *AssetStore, asset: *TileMapAsset) !bool {
        const root_stat = try asset.file.dir.statFile(asset.file.path);
        var changed = root_stat.mtime != asset.file.mtime;
        for (asset.dependencies) |dependency| {
            if ((try dependency.dir.statFile(dependency.path)).mtime != dependency.mtime) changed = true;
        }
        if (!changed) return false;
        const next = try self.loadTileMapAsset(asset.file.path, .{ .overlay_path = asset.overlay_path });
        const generation = nextGeneration(asset.generation);
        asset.deinit();
        asset.* = next;
        asset.generation = generation;
        return true;
    }

    fn loadTileMapAsset(self: *AssetStore, path: []const u8, options: TileMapAssetOptions) !TileMapAsset {
        const file = try AssetFile.load(self.allocator, self.dir, path, 64 * 1024 * 1024);
        errdefer {
            var cleanup = file;
            cleanup.deinit();
        }
        var map = if (std.mem.endsWith(u8, path, ".tmj"))
            try TileMap.loadTiledWithOptions(self.allocator, path, .{ .overlay_path = options.overlay_path })
        else if (std.mem.endsWith(u8, path, ".ldtk")) blk: {
            var project = try TileMap.loadLdtkProjectWithOptions(self.allocator, path, .{ .overlay_path = options.overlay_path });
            errdefer project.deinit();
            if (project.levels.items.len == 0) return error.EmptyLdtkProject;
            const level = project.levels.orderedRemove(0);
            self.allocator.free(level.identifier);
            project.deinit();
            break :blk level.map;
        } else blk: {
            var native = try TileMap.loadNative(self.allocator, path);
            errdefer native.deinit();
            if (options.overlay_path) |overlay_path| {
                try native.addDependency(.overlay, overlay_path);
                try native.applyOverlay(overlay_path);
            }
            break :blk native;
        };
        errdefer map.deinit();
        const dependencies = try self.loadTileMapDependencies(map);
        errdefer {
            for (dependencies) |*entry| entry.deinit();
            self.allocator.free(dependencies);
        }
        const images = try self.decodeTileMapImages(map, dependencies);
        errdefer {
            for (images) |*entry| entry.image.deinit();
            self.allocator.free(images);
        }
        const overlay_path = if (options.overlay_path) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (overlay_path) |value| self.allocator.free(value);
        return .{ .file = file, .map = map, .dependencies = dependencies, .images = images, .overlay_path = overlay_path };
    }

    fn loadTileMapDependencies(self: *AssetStore, map: TileMap) ![]AssetFile {
        const dependencies = try self.allocator.alloc(AssetFile, map.dependencies.items.len);
        var count: usize = 0;
        errdefer {
            for (dependencies[0..count]) |*entry| entry.deinit();
            self.allocator.free(dependencies);
        }
        for (map.dependencies.items) |dependency| {
            dependencies[count] = try AssetFile.load(self.allocator, self.dir, dependency.path, 64 * 1024 * 1024);
            count += 1;
        }
        return dependencies;
    }

    fn decodeTileMapImages(self: *AssetStore, map: TileMap, dependencies: []const AssetFile) ![]TileMapImage {
        var images = std.ArrayListUnmanaged(TileMapImage){};
        errdefer {
            for (images.items) |*entry| entry.image.deinit();
            images.deinit(self.allocator);
        }
        for (map.tilesets.items, 0..) |tileset, tileset_index| {
            if (tileset.kind == .atlas_frames) continue;
            if (tileset.kind == .grid_image) try self.appendTileMapImage(&images, dependencies, @intCast(tileset_index), null, tileset.path);
            for (tileset.image_paths, 0..) |image_path, tile_id| if (image_path) |value| try self.appendTileMapImage(&images, dependencies, @intCast(tileset_index), @intCast(tile_id), value);
        }
        return images.toOwnedSlice(self.allocator);
    }

    fn appendTileMapImage(self: *AssetStore, images: *std.ArrayListUnmanaged(TileMapImage), dependencies: []const AssetFile, tileset: u16, tile_id: ?u32, path: []const u8) !void {
        for (dependencies) |dependency| if (std.mem.eql(u8, dependency.path, path)) {
            var decoded = try Image.decodePng(self.allocator, dependency.bytes);
            errdefer decoded.deinit();
            try images.append(self.allocator, .{ .tileset = tileset, .tile_id = tile_id, .image = decoded });
            return;
        };
        return error.MissingTileMapImageDependency;
    }
};

test "asset reload detects content changes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "asset.txt", .data = "one" });
    var asset = try AssetFile.load(std.testing.allocator, tmp.dir, "asset.txt", 1024);
    defer asset.deinit();

    try std.testing.expectEqualStrings("one", asset.text());
    try std.testing.expect(!try asset.reloadIfChanged());

    var stat = try tmp.dir.statFile("asset.txt");
    try tmp.dir.writeFile(.{ .sub_path = "asset.txt", .data = "two" });
    while ((try tmp.dir.statFile("asset.txt")).mtime == stat.mtime) {
        std.Thread.sleep(1_000_000);
        try tmp.dir.writeFile(.{ .sub_path = "asset.txt", .data = "two" });
        stat = try tmp.dir.statFile("asset.txt");
    }

    try std.testing.expect(try asset.reloadIfChanged());
    try std.testing.expectEqualStrings("two", asset.text());
}

test "asset handles reject stale generations" {
    var store = AssetStore.init(std.testing.allocator, std.fs.cwd());
    defer store.deinit();
    const text = try store.loadText("examples/assets/message.txt");
    const image = try store.loadPng("examples/assets/ball.png");
    const atlas = try store.loadAtlas("examples/assets/atlas.json");
    try std.testing.expect((try store.tryText(text)).len > 0);
    try std.testing.expect((try store.tryImage(image)).width > 0);
    try std.testing.expect((try store.tryAtlas(atlas)).frames.len > 0);
    try std.testing.expectError(error.StaleHandle, store.tryText(.{ .index = text.index, .generation = nextGeneration(text.generation) }));
    try std.testing.expectError(error.StaleHandle, store.tryImage(.{ .index = image.index, .generation = nextGeneration(image.generation) }));
    try std.testing.expectError(error.StaleHandle, store.tryAtlas(.{ .index = atlas.index, .generation = nextGeneration(atlas.generation) }));
    try std.testing.expectError(error.StaleHandle, store.tryTileMap(.{ .index = 0, .generation = 1 }));
}

test "image reload keeps last good asset after invalid edit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const png = try std.fs.cwd().readFileAlloc(std.testing.allocator, "examples/assets/ball.png", 1024 * 1024);
    defer std.testing.allocator.free(png);
    try tmp.dir.writeFile(.{ .sub_path = "ball.png", .data = png });
    var store = AssetStore.init(std.testing.allocator, tmp.dir);
    defer store.deinit();
    const handle = try store.loadPng("ball.png");
    const before = try store.tryImage(handle);
    var stat = try tmp.dir.statFile("ball.png");
    try tmp.dir.writeFile(.{ .sub_path = "ball.png", .data = "invalid" });
    while ((try tmp.dir.statFile("ball.png")).mtime == stat.mtime) {
        std.Thread.sleep(1_000_000);
        try tmp.dir.writeFile(.{ .sub_path = "ball.png", .data = "invalid" });
        stat = try tmp.dir.statFile("ball.png");
    }
    const failed = try store.reloadChanged();
    try std.testing.expectEqual(ReloadStatus.failed, failed[0].status);
    try std.testing.expect(failed[0].err != null);
    const preserved = try store.tryImage(handle);
    try std.testing.expectEqual(before.width, preserved.width);
    try tmp.dir.writeFile(.{ .sub_path = "ball.png", .data = png });
    while ((try tmp.dir.statFile("ball.png")).mtime == stat.mtime) {
        std.Thread.sleep(1_000_000);
        try tmp.dir.writeFile(.{ .sub_path = "ball.png", .data = png });
        stat = try tmp.dir.statFile("ball.png");
    }
    const changed = try store.reloadChanged();
    try std.testing.expectEqual(ReloadStatus.changed, changed[0].status);
    try std.testing.expectError(error.StaleHandle, store.tryImage(handle));
}
