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

pub const TextHandle = struct { index: usize };
pub const ImageHandle = struct { index: usize };
pub const AtlasHandle = struct { index: usize };
pub const TileMapHandle = struct { index: usize };

pub const ReloadStatus = enum {
    changed,
    failed,
};

pub const ReloadEvent = struct {
    path: []const u8,
    status: ReloadStatus,
};

const TextAsset = struct {
    file: AssetFile,

    fn deinit(self: *TextAsset) void {
        self.file.deinit();
    }
};

const ImageAsset = struct {
    file: AssetFile,
    image: Image,

    fn deinit(self: *ImageAsset) void {
        self.image.deinit();
        self.file.deinit();
    }
};

const AtlasAsset = struct {
    json_file: AssetFile,
    image_file: AssetFile,
    atlas: Atlas,

    fn deinit(self: *AtlasAsset) void {
        self.atlas.deinit();
        self.image_file.deinit();
        self.json_file.deinit();
    }
};

const TileMapAsset = struct {
    file: AssetFile,
    map: TileMap,

    fn deinit(self: *TileMapAsset) void {
        self.map.deinit();
        self.file.deinit();
    }
};

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
        return .{ .index = index };
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
        return .{ .index = index };
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
        return .{ .index = index };
    }

    pub fn loadTileMap(self: *AssetStore, path: []const u8) !TileMapHandle {
        const file = try AssetFile.load(self.allocator, self.dir, path, 64 * 1024 * 1024);
        errdefer {
            var cleanup = file;
            cleanup.deinit();
        }
        const map = try TileMap.decodeNative(self.allocator, file.bytes);
        errdefer {
            var cleanup = map;
            cleanup.deinit();
        }
        const index = self.tile_maps.items.len;
        try self.tile_maps.append(self.allocator, .{ .file = file, .map = map });
        return .{ .index = index };
    }

    pub fn text(self: AssetStore, handle: TextHandle) []const u8 {
        return self.texts.items[handle.index].file.text();
    }

    pub fn image(self: AssetStore, handle: ImageHandle) Image {
        return self.images.items[handle.index].image;
    }

    pub fn atlas(self: AssetStore, handle: AtlasHandle) Atlas {
        return self.atlases.items[handle.index].atlas;
    }

    pub fn atlasPtr(self: *AssetStore, handle: AtlasHandle) *const Atlas {
        return &self.atlases.items[handle.index].atlas;
    }

    pub fn tileMap(self: AssetStore, handle: TileMapHandle) TileMap {
        return self.tile_maps.items[handle.index].map;
    }

    pub fn tileMapPtr(self: *AssetStore, handle: TileMapHandle) *const TileMap {
        return &self.tile_maps.items[handle.index].map;
    }

    pub fn reloadChanged(self: *AssetStore) ![]const ReloadEvent {
        self.events.clearRetainingCapacity();

        for (self.texts.items) |*asset| {
            if (asset.file.reloadIfChanged() catch {
                try self.events.append(self.allocator, .{ .path = asset.file.path, .status = .failed });
                continue;
            }) {
                try self.events.append(self.allocator, .{ .path = asset.file.path, .status = .changed });
            }
        }

        for (self.images.items) |*asset| {
            const stat = asset.file.dir.statFile(asset.file.path) catch {
                try self.events.append(self.allocator, .{ .path = asset.file.path, .status = .failed });
                continue;
            };
            if (stat.mtime == asset.file.mtime) continue;

            const bytes = asset.file.dir.readFileAlloc(self.allocator, asset.file.path, asset.file.max_bytes) catch {
                try self.events.append(self.allocator, .{ .path = asset.file.path, .status = .failed });
                continue;
            };

            const next = Image.decodePng(self.allocator, bytes) catch {
                self.allocator.free(bytes);
                try self.events.append(self.allocator, .{ .path = asset.file.path, .status = .failed });
                continue;
            };

            asset.image.deinit();
            self.allocator.free(asset.file.bytes);
            asset.file.bytes = bytes;
            asset.file.mtime = stat.mtime;
            asset.image = next;
            try self.events.append(self.allocator, .{ .path = asset.file.path, .status = .changed });
        }

        for (self.atlases.items) |*asset| {
            if (self.reloadAtlas(asset) catch {
                try self.events.append(self.allocator, .{ .path = asset.json_file.path, .status = .failed });
                continue;
            }) {
                try self.events.append(self.allocator, .{ .path = asset.json_file.path, .status = .changed });
            }
        }

        for (self.tile_maps.items) |*asset| {
            if (self.reloadTileMap(asset) catch {
                try self.events.append(self.allocator, .{ .path = asset.file.path, .status = .failed });
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

        asset.deinit();
        asset.* = .{ .json_file = json_file, .image_file = image_file, .atlas = decoded_atlas };
        return true;
    }

    fn reloadTileMap(self: *AssetStore, asset: *TileMapAsset) !bool {
        const stat = try asset.file.dir.statFile(asset.file.path);
        if (stat.mtime == asset.file.mtime) return false;
        const bytes = try asset.file.dir.readFileAlloc(self.allocator, asset.file.path, asset.file.max_bytes);
        errdefer self.allocator.free(bytes);
        var next = try TileMap.decodeNative(self.allocator, bytes);
        errdefer next.deinit();
        self.allocator.free(asset.file.bytes);
        asset.file.bytes = bytes;
        asset.file.mtime = stat.mtime;
        asset.map.deinit();
        asset.map = next;
        return true;
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
