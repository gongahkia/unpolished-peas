const std = @import("std");
const atlas_mod = @import("atlas.zig");
const Atlas = atlas_mod.Atlas;
const Sound = @import("audio.zig").Sound;
const Font = @import("font_asset.zig").Font;
const FontLoadOptions = @import("font_asset.zig").LoadOptions;
const Image = @import("image.zig").Image;
const map_source = @import("map_source.zig");
const TileMap = @import("tilemap.zig").TileMap;

pub const AssetFile = struct { // owns path and bytes allocated by load; call deinit once.
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

pub const TextHandle = struct { index: usize, generation: u32 }; // borrows an AssetStore entry; use tryText for stale-handle errors.
pub const ImageHandle = struct { index: usize, generation: u32 }; // borrows an AssetStore entry; use tryImage for stale-handle errors.
pub const AudioHandle = struct { index: usize, generation: u32 }; // borrows an AssetStore entry; use trySound for stale-handle errors.
pub const AtlasHandle = struct { index: usize, generation: u32 }; // borrows an AssetStore entry; use tryAtlas for stale-handle errors.
pub const FontHandle = struct { index: usize, generation: u32 }; // borrows an AssetStore entry; use tryFont for stale-handle errors.
pub const ShaderAssetHandle = struct { index: usize, generation: u32 }; // borrows an AssetStore entry; use tryShaderSource for stale-handle errors.
pub const TileMapHandle = struct { index: usize, generation: u32 }; // borrows an AssetStore entry; use tryTileMap for stale-handle errors.

pub const TileMapAssetOptions = struct {
    overlay_path: ?[]const u8 = null,
};

pub const AssetStats = struct {
    texts: usize,
    images: usize,
    sounds: usize,
    atlases: usize,
    fonts: usize,
    shaders: usize,
    tile_maps: usize,
    reload_events: usize,
};

pub const ReloadStatus = enum {
    changed,
    failed,
};

pub const ReloadFailureClass = enum {
    io,
    source,
    dependency,
    decode,
};

pub const ReloadEvent = struct {
    path: []const u8,
    status: ReloadStatus,
    err: ?anyerror = null,
    line: usize = 1,
    column: usize = 1,
    failure_class: ?ReloadFailureClass = null,
    retained_content: bool = false,
    message: []const u8 = "",
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

const SoundAsset = struct {
    file: AssetFile,
    sound: Sound,
    generation: u32 = 1,

    fn deinit(self: *SoundAsset) void {
        self.sound.deinit();
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

const FontKind = enum { truetype, bitmap };

const FontAsset = struct {
    kind: FontKind,
    font_file: AssetFile,
    image_file: ?AssetFile = null,
    font: Font,
    options: FontLoadOptions = .{},
    generation: u32 = 1,

    fn deinit(self: *FontAsset) void {
        self.font.deinit();
        if (self.image_file) |*file| file.deinit();
        self.font_file.deinit();
    }
};

const ShaderAsset = struct {
    file: AssetFile,
    generation: u32 = 1,

    fn deinit(self: *ShaderAsset) void {
        self.file.deinit();
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

pub const AssetStore = struct { // owns loaded assets and any directory opened by initAbsolute/initExecutable; call deinit once.
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    owned_dir: ?std.fs.Dir = null,
    root_path: ?[]u8 = null,
    texts: std.ArrayListUnmanaged(TextAsset) = .{},
    images: std.ArrayListUnmanaged(ImageAsset) = .{},
    sounds: std.ArrayListUnmanaged(SoundAsset) = .{},
    atlases: std.ArrayListUnmanaged(AtlasAsset) = .{},
    fonts: std.ArrayListUnmanaged(FontAsset) = .{},
    shaders: std.ArrayListUnmanaged(ShaderAsset) = .{},
    tile_maps: std.ArrayListUnmanaged(TileMapAsset) = .{},
    events: std.ArrayListUnmanaged(ReloadEvent) = .{},

    pub fn init(allocator: std.mem.Allocator, dir: std.fs.Dir) AssetStore {
        return .{ .allocator = allocator, .dir = dir };
    }

    pub fn stats(self: AssetStore) AssetStats {
        return .{
            .texts = self.texts.items.len,
            .images = self.images.items.len,
            .sounds = self.sounds.items.len,
            .atlases = self.atlases.items.len,
            .fonts = self.fonts.items.len,
            .shaders = self.shaders.items.len,
            .tile_maps = self.tile_maps.items.len,
            .reload_events = self.events.items.len,
        };
    }

    pub fn initAbsolute(allocator: std.mem.Allocator, root_path: []const u8) !AssetStore {
        if (!std.fs.path.isAbsolute(root_path)) return error.AssetRootMustBeAbsolute;
        const owned_path = try allocator.dupe(u8, root_path);
        errdefer allocator.free(owned_path);
        const dir = try std.fs.openDirAbsolute(owned_path, .{});
        return .{ .allocator = allocator, .dir = dir, .owned_dir = dir, .root_path = owned_path };
    }

    pub fn initExecutable(allocator: std.mem.Allocator) !AssetStore {
        const environment_root = std.process.getEnvVarOwned(allocator, "UP_ASSET_ROOT") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        };
        if (environment_root) |root_path| {
            defer allocator.free(root_path);
            return initAbsolute(allocator, root_path);
        }

        const executable_path = try std.fs.selfExePathAlloc(allocator);
        defer allocator.free(executable_path);
        const executable_dir = std.fs.path.dirname(executable_path) orelse return error.InvalidExecutablePath;

        const beside_executable = try std.fs.path.join(allocator, &.{ executable_dir, "assets" });
        defer allocator.free(beside_executable);
        return initAbsolute(allocator, beside_executable) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => blk: {
                const beside_prefix = try std.fs.path.join(allocator, &.{ executable_dir, "..", "assets" });
                defer allocator.free(beside_prefix);
                break :blk initAbsolute(allocator, beside_prefix);
            },
            else => return err,
        };
    }

    pub fn deinit(self: *AssetStore) void {
        for (self.texts.items) |*asset| asset.deinit();
        for (self.images.items) |*asset| asset.deinit();
        for (self.sounds.items) |*asset| asset.deinit();
        for (self.atlases.items) |*asset| asset.deinit();
        for (self.fonts.items) |*asset| asset.deinit();
        for (self.shaders.items) |*asset| asset.deinit();
        for (self.tile_maps.items) |*asset| asset.deinit();
        self.texts.deinit(self.allocator);
        self.images.deinit(self.allocator);
        self.sounds.deinit(self.allocator);
        self.atlases.deinit(self.allocator);
        self.fonts.deinit(self.allocator);
        self.shaders.deinit(self.allocator);
        self.tile_maps.deinit(self.allocator);
        self.events.deinit(self.allocator);
        if (self.root_path) |path| self.allocator.free(path);
        if (self.owned_dir) |*dir| dir.close();
        self.* = undefined;
    }

    pub fn assetPath(self: AssetStore, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        const root_path = self.root_path orelse return error.AssetRootUnavailable;
        return std.fs.path.join(allocator, &.{ root_path, path });
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

    pub fn loadImage(self: *AssetStore, path: []const u8) !ImageHandle {
        const file = try AssetFile.load(self.allocator, self.dir, path, 32 * 1024 * 1024);
        errdefer {
            var cleanup = file;
            cleanup.deinit();
        }

        const decoded = try Image.decode(self.allocator, file.bytes, .{});
        errdefer {
            var cleanup = decoded;
            cleanup.deinit();
        }

        const index = self.images.items.len;
        try self.images.append(self.allocator, .{ .file = file, .image = decoded });
        return .{ .index = index, .generation = 1 };
    }

    pub fn loadSound(self: *AssetStore, path: []const u8) !AudioHandle {
        const asset = try self.loadSoundAsset(path);
        errdefer {
            var cleanup = asset;
            cleanup.deinit();
        }
        const index = self.sounds.items.len;
        try self.sounds.append(self.allocator, asset);
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

    pub fn loadFont(self: *AssetStore, path: []const u8, options: FontLoadOptions) !FontHandle {
        const asset = if (std.mem.endsWith(u8, path, ".fnt")) try self.loadBitmapFontAsset(path) else try self.loadFontAsset(path, options);
        errdefer {
            var cleanup = asset;
            cleanup.deinit();
        }
        const index = self.fonts.items.len;
        try self.fonts.append(self.allocator, asset);
        return .{ .index = index, .generation = 1 };
    }

    pub fn loadShader(self: *AssetStore, path: []const u8) !ShaderAssetHandle {
        const asset = try self.loadShaderAsset(path);
        errdefer {
            var cleanup = asset;
            cleanup.deinit();
        }
        const index = self.shaders.items.len;
        try self.shaders.append(self.allocator, asset);
        return .{ .index = index, .generation = 1 };
    }

    pub fn loadTileMap(self: *AssetStore, path: []const u8, options: TileMapAssetOptions) !TileMapHandle {
        const asset = try self.loadTileMapAsset(path, options, null);
        errdefer {
            var cleanup = asset;
            cleanup.deinit();
        }
        const index = self.tile_maps.items.len;
        try self.tile_maps.append(self.allocator, asset);
        return .{ .index = index, .generation = 1 };
    }

    pub fn tryText(self: AssetStore, handle: TextHandle) ![]const u8 {
        if (handle.index >= self.texts.items.len or self.texts.items[handle.index].generation != handle.generation) return error.StaleHandle;
        return self.texts.items[handle.index].file.text();
    }

    pub fn latestText(self: AssetStore, handle: TextHandle) ![]const u8 { // accepts stale generations for reload continuity; invalid indexes return error.InvalidHandle.
        if (handle.index >= self.texts.items.len) return error.InvalidHandle;
        return self.texts.items[handle.index].file.text();
    }

    pub fn tryImage(self: AssetStore, handle: ImageHandle) !Image {
        if (handle.index >= self.images.items.len or self.images.items[handle.index].generation != handle.generation) return error.StaleHandle;
        return self.images.items[handle.index].image;
    }

    pub fn tryImagePtr(self: *AssetStore, handle: ImageHandle) !*const Image {
        if (handle.index >= self.images.items.len or self.images.items[handle.index].generation != handle.generation) return error.StaleHandle;
        return &self.images.items[handle.index].image;
    }

    pub fn latestImagePtr(self: *AssetStore, handle: ImageHandle) !*const Image { // accepts stale generations for reload continuity; invalid indexes return error.InvalidHandle.
        if (handle.index >= self.images.items.len) return error.InvalidHandle;
        return &self.images.items[handle.index].image;
    }

    pub fn trySound(self: AssetStore, handle: AudioHandle) !Sound {
        if (handle.index >= self.sounds.items.len or self.sounds.items[handle.index].generation != handle.generation) return error.StaleHandle;
        return self.sounds.items[handle.index].sound;
    }

    pub fn trySoundPtr(self: *AssetStore, handle: AudioHandle) !*const Sound {
        if (handle.index >= self.sounds.items.len or self.sounds.items[handle.index].generation != handle.generation) return error.StaleHandle;
        return &self.sounds.items[handle.index].sound;
    }

    pub fn tryAtlas(self: AssetStore, handle: AtlasHandle) !Atlas {
        if (handle.index >= self.atlases.items.len or self.atlases.items[handle.index].generation != handle.generation) return error.StaleHandle;
        return self.atlases.items[handle.index].atlas;
    }

    pub fn tryAtlasPtr(self: *AssetStore, handle: AtlasHandle) !*const Atlas {
        if (handle.index >= self.atlases.items.len or self.atlases.items[handle.index].generation != handle.generation) return error.StaleHandle;
        return &self.atlases.items[handle.index].atlas;
    }

    pub fn latestAtlasPtr(self: *AssetStore, handle: AtlasHandle) !*const Atlas { // accepts stale generations for reload continuity; invalid indexes return error.InvalidHandle.
        if (handle.index >= self.atlases.items.len) return error.InvalidHandle;
        return &self.atlases.items[handle.index].atlas;
    }

    pub fn tryFont(self: AssetStore, handle: FontHandle) !Font {
        if (handle.index >= self.fonts.items.len or self.fonts.items[handle.index].generation != handle.generation) return error.StaleHandle;
        return self.fonts.items[handle.index].font;
    }

    pub fn tryFontPtr(self: *AssetStore, handle: FontHandle) !*const Font {
        if (handle.index >= self.fonts.items.len or self.fonts.items[handle.index].generation != handle.generation) return error.StaleHandle;
        return &self.fonts.items[handle.index].font;
    }

    pub fn latestFontPtr(self: *AssetStore, handle: FontHandle) !*const Font { // accepts stale generations for reload continuity; invalid indexes return error.InvalidHandle.
        if (handle.index >= self.fonts.items.len) return error.InvalidHandle;
        return &self.fonts.items[handle.index].font;
    }

    pub fn tryShaderSource(self: AssetStore, handle: ShaderAssetHandle) ![]const u8 {
        if (handle.index >= self.shaders.items.len or self.shaders.items[handle.index].generation != handle.generation) return error.StaleHandle;
        return self.shaders.items[handle.index].file.text();
    }

    pub fn latestShaderSource(self: AssetStore, handle: ShaderAssetHandle) ![]const u8 {
        if (handle.index >= self.shaders.items.len) return error.InvalidHandle;
        return self.shaders.items[handle.index].file.text();
    }

    pub fn tryTileMap(self: AssetStore, handle: TileMapHandle) !TileMap {
        if (handle.index >= self.tile_maps.items.len or self.tile_maps.items[handle.index].generation != handle.generation) return error.StaleHandle;
        return self.tile_maps.items[handle.index].map;
    }

    pub fn tryTileMapPtr(self: *AssetStore, handle: TileMapHandle) !*const TileMap {
        if (handle.index >= self.tile_maps.items.len or self.tile_maps.items[handle.index].generation != handle.generation) return error.StaleHandle;
        return &self.tile_maps.items[handle.index].map;
    }

    pub fn drawTileMap(self: *AssetStore, handle: TileMapHandle, camera: *const @import("camera.zig").Camera2D, canvas: *@import("canvas.zig").Canvas, time: f32) !void {
        _ = try self.tryTileMap(handle);
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
                try self.appendReloadFailure(asset.file.path, err, .io);
                continue;
            }) {
                asset.generation +%= 1;
                if (asset.generation == 0) asset.generation = 1;
                try self.events.append(self.allocator, .{ .path = asset.file.path, .status = .changed });
            }
        }

        for (self.images.items) |*asset| {
            const stat = asset.file.dir.statFile(asset.file.path) catch |err| {
                try self.appendReloadFailure(asset.file.path, err, .io);
                continue;
            };
            if (stat.mtime == asset.file.mtime) continue;

            const bytes = asset.file.dir.readFileAlloc(self.allocator, asset.file.path, asset.file.max_bytes) catch |err| {
                try self.appendReloadFailure(asset.file.path, err, .io);
                continue;
            };

            const next = Image.decode(self.allocator, bytes, .{}) catch |err| {
                self.allocator.free(bytes);
                try self.appendReloadFailure(asset.file.path, err, .decode);
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

        for (self.sounds.items) |*asset| {
            if (self.reloadSound(asset) catch |err| {
                try self.appendReloadFailure(asset.file.path, err, .decode);
                continue;
            }) {
                try self.events.append(self.allocator, .{ .path = asset.file.path, .status = .changed });
            }
        }

        for (self.atlases.items) |*asset| {
            if (self.reloadAtlas(asset) catch |err| {
                try self.appendReloadFailure(asset.json_file.path, err, .decode);
                continue;
            }) {
                try self.events.append(self.allocator, .{ .path = asset.json_file.path, .status = .changed });
            }
        }

        for (self.fonts.items) |*asset| {
            if (self.reloadFont(asset) catch |err| {
                try self.appendReloadFailure(asset.font_file.path, err, .decode);
                continue;
            }) {
                try self.events.append(self.allocator, .{ .path = asset.font_file.path, .status = .changed });
            }
        }

        for (self.shaders.items) |*asset| {
            if (self.reloadShader(asset) catch |err| {
                try self.appendReloadFailure(asset.file.path, err, .io);
                continue;
            }) {
                try self.events.append(self.allocator, .{ .path = asset.file.path, .status = .changed });
            }
        }

        for (self.tile_maps.items) |*asset| {
            var diagnostic = map_source.Diagnostic{};
            if (self.reloadTileMap(asset, &diagnostic) catch |err| {
                const failure_class = mapReloadFailureClass(err);
                try self.appendReloadFailureWithLocation(asset.file.path, err, failure_class, diagnostic.line, diagnostic.column, if (failure_class == .source) diagnostic.message else @errorName(err));
                continue;
            }) {
                try self.events.append(self.allocator, .{ .path = asset.file.path, .status = .changed });
            }
        }

        return self.events.items;
    }

    fn appendReloadFailure(self: *AssetStore, path: []const u8, err: anyerror, failure_class: ReloadFailureClass) !void {
        try self.appendReloadFailureWithLocation(path, err, failure_class, 1, 1, @errorName(err));
    }

    fn appendReloadFailureWithLocation(self: *AssetStore, path: []const u8, err: anyerror, failure_class: ReloadFailureClass, line: usize, column: usize, message: []const u8) !void {
        try self.events.append(self.allocator, .{
            .path = path,
            .status = .failed,
            .err = err,
            .line = line,
            .column = column,
            .failure_class = failure_class,
            .retained_content = true,
            .message = message,
        });
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

    fn reloadSound(self: *AssetStore, asset: *SoundAsset) !bool {
        if ((try asset.file.dir.statFile(asset.file.path)).mtime == asset.file.mtime) return false;
        const next = try self.loadSoundAsset(asset.file.path);
        const generation = nextGeneration(asset.generation);
        asset.deinit();
        asset.* = next;
        asset.generation = generation;
        return true;
    }

    fn reloadFont(self: *AssetStore, asset: *FontAsset) !bool {
        const font_stat = try asset.font_file.dir.statFile(asset.font_file.path);
        var changed = font_stat.mtime != asset.font_file.mtime;
        if (asset.image_file) |image_file| {
            if ((try image_file.dir.statFile(image_file.path)).mtime != image_file.mtime) changed = true;
        }
        if (!changed) return false;
        const next = switch (asset.kind) {
            .truetype => try self.loadFontAsset(asset.font_file.path, asset.options),
            .bitmap => try self.loadBitmapFontAsset(asset.font_file.path),
        };
        const generation = nextGeneration(asset.generation);
        asset.deinit();
        asset.* = next;
        asset.generation = generation;
        return true;
    }

    fn reloadShader(self: *AssetStore, asset: *ShaderAsset) !bool {
        if ((try asset.file.dir.statFile(asset.file.path)).mtime == asset.file.mtime) return false;
        const next = try self.loadShaderAsset(asset.file.path);
        const generation = nextGeneration(asset.generation);
        asset.deinit();
        asset.* = next;
        asset.generation = generation;
        return true;
    }

    fn reloadTileMap(self: *AssetStore, asset: *TileMapAsset, diagnostic: *map_source.Diagnostic) !bool {
        const root_stat = try asset.file.dir.statFile(asset.file.path);
        var changed = root_stat.mtime != asset.file.mtime;
        for (asset.dependencies) |dependency| {
            if ((try dependency.dir.statFile(dependency.path)).mtime != dependency.mtime) changed = true;
        }
        if (!changed) return false;
        const next = try self.loadTileMapAsset(asset.file.path, .{ .overlay_path = asset.overlay_path }, diagnostic);
        const generation = nextGeneration(asset.generation);
        asset.deinit();
        asset.* = next;
        asset.generation = generation;
        return true;
    }

    fn loadFontAsset(self: *AssetStore, path: []const u8, options: FontLoadOptions) !FontAsset {
        const file = try AssetFile.load(self.allocator, self.dir, path, 32 * 1024 * 1024);
        errdefer {
            var cleanup = file;
            cleanup.deinit();
        }
        const decoded = try Font.decodeTrueType(self.allocator, file.bytes, options);
        errdefer {
            var cleanup = decoded;
            cleanup.deinit();
        }
        return .{ .kind = .truetype, .font_file = file, .font = decoded, .options = options };
    }

    fn loadSoundAsset(self: *AssetStore, path: []const u8) !SoundAsset {
        const file = try AssetFile.load(self.allocator, self.dir, path, 128 * 1024 * 1024);
        errdefer {
            var cleanup = file;
            cleanup.deinit();
        }
        const decoded = if (std.mem.endsWith(u8, path, ".wav"))
            try Sound.decodeWav(self.allocator, file.bytes)
        else if (std.mem.endsWith(u8, path, ".ogg"))
            try Sound.decodeOgg(self.allocator, file.bytes)
        else
            return error.UnsupportedSoundAsset;
        errdefer {
            var cleanup = decoded;
            cleanup.deinit();
        }
        return .{ .file = file, .sound = decoded };
    }

    fn loadShaderAsset(self: *AssetStore, path: []const u8) !ShaderAsset {
        const file = try AssetFile.load(self.allocator, self.dir, path, 64 * 1024);
        errdefer {
            var cleanup = file;
            cleanup.deinit();
        }
        return .{ .file = file };
    }

    fn loadBitmapFontAsset(self: *AssetStore, path: []const u8) !FontAsset {
        const font_file = try AssetFile.load(self.allocator, self.dir, path, 8 * 1024 * 1024);
        errdefer {
            var cleanup = font_file;
            cleanup.deinit();
        }
        const image_rel = try Font.bitmapImagePath(self.allocator, font_file.bytes);
        defer self.allocator.free(image_rel);
        const image_path = try atlas_mod.resolveSiblingPath(self.allocator, path, image_rel);
        defer self.allocator.free(image_path);
        const image_file = try AssetFile.load(self.allocator, self.dir, image_path, 32 * 1024 * 1024);
        errdefer {
            var cleanup = image_file;
            cleanup.deinit();
        }
        const decoded = try Font.decodeBitmap(self.allocator, font_file.bytes, image_file.bytes);
        errdefer {
            var cleanup = decoded;
            cleanup.deinit();
        }
        return .{ .kind = .bitmap, .font_file = font_file, .image_file = image_file, .font = decoded };
    }

    fn loadTileMapAsset(self: *AssetStore, path: []const u8, options: TileMapAssetOptions, diagnostic: ?*map_source.Diagnostic) !TileMapAsset {
        const file = try AssetFile.load(self.allocator, self.dir, path, 64 * 1024 * 1024);
        errdefer {
            var cleanup = file;
            cleanup.deinit();
        }
        var map = blk: {
            var ignored_diagnostic = map_source.Diagnostic{};
            var parsed = try map_source.parse(self.allocator, file.bytes, diagnostic orelse &ignored_diagnostic);
            defer parsed.deinit(self.allocator);
            var native = try parsed.build(self.allocator);
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
            var decoded = try Image.decode(self.allocator, dependency.bytes, .{});
            errdefer decoded.deinit();
            try images.append(self.allocator, .{ .tileset = tileset, .tile_id = tile_id, .image = decoded });
            return;
        };
        return error.MissingTileMapImageDependency;
    }
};

fn mapReloadFailureClass(err: anyerror) ReloadFailureClass {
    return switch (err) {
        error.ParseZon, error.InvalidMapSource => .source,
        error.MissingTileMapImageDependency, error.UnknownTileSet, error.InvalidParentLayer => .dependency,
        error.FileNotFound => .io,
        else => .decode,
    };
}

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
    const image = try store.loadImage("examples/assets/ball.png");
    const sound = try store.loadSound("examples/assets/blip.wav");
    const atlas = try store.loadAtlas("examples/assets/atlas.json");
    const truetype = try store.loadFont("examples/assets/fonts/Basic-Regular.ttf", .{});
    const opentype = try store.loadFont("examples/assets/fonts/SourceSans3-Regular.otf", .{});
    const bitmap = try store.loadFont("examples/assets/fonts/bitmap.fnt", .{});
    try std.testing.expect((try store.tryText(text)).len > 0);
    try std.testing.expect((try store.tryImage(image)).width > 0);
    try std.testing.expect((try store.trySound(sound)).frames.len > 0);
    try std.testing.expect((try store.tryAtlas(atlas)).frames.len > 0);
    try std.testing.expect((try store.tryFont(truetype)).glyphForCodepoint(0x00c9).?.width > 0);
    try std.testing.expect((try store.tryFont(opentype)).glyphForCodepoint(0x00c9).?.width > 0);
    try std.testing.expect((try store.tryFont(bitmap)).glyphForCodepoint('B').?.width > 0);
    try std.testing.expectError(error.StaleHandle, store.tryText(.{ .index = text.index, .generation = nextGeneration(text.generation) }));
    try std.testing.expectError(error.StaleHandle, store.tryImage(.{ .index = image.index, .generation = nextGeneration(image.generation) }));
    try std.testing.expectError(error.StaleHandle, store.trySound(.{ .index = sound.index, .generation = nextGeneration(sound.generation) }));
    try std.testing.expectError(error.StaleHandle, store.tryAtlas(.{ .index = atlas.index, .generation = nextGeneration(atlas.generation) }));
    try std.testing.expectError(error.StaleHandle, store.tryFont(.{ .index = truetype.index, .generation = nextGeneration(truetype.generation) }));
    try std.testing.expectError(error.StaleHandle, store.tryFont(.{ .index = opentype.index, .generation = nextGeneration(opentype.generation) }));
    try std.testing.expectError(error.StaleHandle, store.tryTileMap(.{ .index = 0, .generation = 1 }));
}

test "asset store exposes canonical loaders only" {
    try std.testing.expect(@hasDecl(AssetStore, "loadImage"));
    try std.testing.expect(@hasDecl(AssetStore, "loadAtlas"));
    try std.testing.expect(@hasDecl(AssetStore, "loadFont"));
    try std.testing.expect(@hasDecl(AssetStore, "loadSound"));
    try std.testing.expect(@hasDecl(AssetStore, "loadTileMap"));
    try std.testing.expect(!@hasDecl(AssetStore, "loadPng"));
    try std.testing.expect(!@hasDecl(AssetStore, "loadBitmapFont"));
    try std.testing.expect(!@hasDecl(AssetStore, "loadFontWithOptions"));
    try std.testing.expect(!@hasDecl(AssetStore, "loadTileMapWithOptions"));
}

test "asset store exposes checked handle accessors" {
    try std.testing.expect(@hasDecl(AssetStore, "tryText"));
    try std.testing.expect(@hasDecl(AssetStore, "tryImage"));
    try std.testing.expect(@hasDecl(AssetStore, "tryImagePtr"));
    try std.testing.expect(@hasDecl(AssetStore, "tryAtlas"));
    try std.testing.expect(@hasDecl(AssetStore, "tryAtlasPtr"));
    try std.testing.expect(@hasDecl(AssetStore, "tryFont"));
    try std.testing.expect(@hasDecl(AssetStore, "tryFontPtr"));
    try std.testing.expect(@hasDecl(AssetStore, "tryTileMap"));
    try std.testing.expect(@hasDecl(AssetStore, "tryTileMapPtr"));
    try std.testing.expect(!@hasDecl(AssetStore, "text"));
    try std.testing.expect(!@hasDecl(AssetStore, "image"));
    try std.testing.expect(!@hasDecl(AssetStore, "imagePtr"));
    try std.testing.expect(!@hasDecl(AssetStore, "atlas"));
    try std.testing.expect(!@hasDecl(AssetStore, "atlasPtr"));
    try std.testing.expect(!@hasDecl(AssetStore, "font"));
    try std.testing.expect(!@hasDecl(AssetStore, "fontPtr"));
    try std.testing.expect(!@hasDecl(AssetStore, "tileMap"));
    try std.testing.expect(!@hasDecl(AssetStore, "tileMapPtr"));
}

test "tile-map draw rejects stale handles" {
    var store = AssetStore.init(std.testing.allocator, std.fs.cwd());
    defer store.deinit();
    var canvas = try @import("canvas.zig").Canvas.init(std.testing.allocator, 1, 1);
    defer canvas.deinit();
    const camera = @import("camera.zig").Camera2D{};
    try std.testing.expectError(error.StaleHandle, store.drawTileMap(.{ .index = 0, .generation = 1 }, &camera, &canvas, 0));
}

test "native tile maps share camera canvas clip and blend semantics" {
    const Canvas = @import("canvas.zig").Canvas;
    const CameraCanvas = @import("camera_canvas.zig").CameraCanvas;
    const Camera2D = @import("camera.zig").Camera2D;
    const Color = @import("color.zig").Color;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const map = try std.fs.cwd().readFileAlloc(std.testing.allocator, "examples/assets/topdown.upmap", 256 * 1024);
    defer std.testing.allocator.free(map);
    const image = try std.fs.cwd().readFileAlloc(std.testing.allocator, "examples/assets/ball.png", 1024 * 1024);
    defer std.testing.allocator.free(image);
    try tmp.dir.writeFile(.{ .sub_path = "topdown.upmap", .data = map });
    try tmp.dir.writeFile(.{ .sub_path = "ball.png", .data = image });
    var store = AssetStore.init(std.testing.allocator, tmp.dir);
    defer store.deinit();
    const handle = try store.loadTileMap("topdown.upmap", .{});
    const camera = Camera2D{ .position = .{ .x = 6, .y = 6 }, .viewport = .{ .x = 2, .y = 2, .w = 4, .h = 4 } };
    const background = Color.rgb(1, 2, 3);
    var actual = try Canvas.init(std.testing.allocator, 8, 8);
    defer actual.deinit();
    actual.clear(background);
    _ = actual.setBlend(.additive);
    try store.drawTileMap(handle, &camera, &actual, 0);

    var expected = try Canvas.init(std.testing.allocator, 8, 8);
    defer expected.deinit();
    expected.clear(background);
    _ = expected.setBlend(.additive);
    const asset = &store.tile_maps.items[handle.index];
    const Resolver = struct {
        images: []const TileMapImage,
        fn resolve(context: *const anyopaque, tileset: u16, tile_id: u32) ?Image {
            const self_resolver: *const @This() = @ptrCast(@alignCast(context));
            for (self_resolver.images) |entry| if (entry.tileset == tileset and (entry.tile_id == null or entry.tile_id.? == tile_id)) return entry.image;
            return null;
        }
    };
    const resolver = Resolver{ .images = asset.images };
    asset.map.drawResolvedImagesAt(CameraCanvas.init(&expected, &camera), .{ .context = &resolver, .resolve = Resolver.resolve }, 0);
    try std.testing.expectEqualSlices(Color, expected.pixels, actual.pixels);
    try std.testing.expectEqual(background, actual.get(1, 4).?);
    var changed = false;
    for (2..6) |y| {
        for (2..6) |x| {
            if (!std.meta.eql(actual.get(@intCast(x), @intCast(y)).?, background)) changed = true;
        }
    }
    try std.testing.expect(changed);
}

test "tile-map reload failures retain source diagnostics and last valid content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const map = try std.fs.cwd().readFileAlloc(std.testing.allocator, "examples/assets/topdown.upmap", 256 * 1024);
    defer std.testing.allocator.free(map);
    const image = try std.fs.cwd().readFileAlloc(std.testing.allocator, "examples/assets/ball.png", 1024 * 1024);
    defer std.testing.allocator.free(image);
    try tmp.dir.writeFile(.{ .sub_path = "topdown.upmap", .data = map });
    try tmp.dir.writeFile(.{ .sub_path = "ball.png", .data = image });
    var store = AssetStore.init(std.testing.allocator, tmp.dir);
    defer store.deinit();
    const handle = try store.loadTileMap("topdown.upmap", .{});

    const invalid =
        \\.{
        \\    .format = "invalid",
        \\    .version = 1,
        \\    .metadata = .{ .name = "invalid", .projection = .orthogonal, .tile_width = 8, .tile_height = 8, .chunk_size = 8 },
        \\    .tilesets = .{},
        \\    .layers = .{},
        \\}
    ;
    var stat = try tmp.dir.statFile("topdown.upmap");
    try tmp.dir.writeFile(.{ .sub_path = "topdown.upmap", .data = invalid });
    while ((try tmp.dir.statFile("topdown.upmap")).mtime == stat.mtime) {
        std.Thread.sleep(1_000_000);
        try tmp.dir.writeFile(.{ .sub_path = "topdown.upmap", .data = invalid });
        stat = try tmp.dir.statFile("topdown.upmap");
    }

    const events = try store.reloadChanged();
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqual(ReloadStatus.failed, events[0].status);
    try std.testing.expectEqual(error.InvalidMapSource, events[0].err.?);
    try std.testing.expectEqual(@as(usize, 2), events[0].line);
    try std.testing.expect(events[0].column > 0);
    try std.testing.expectEqual(ReloadFailureClass.source, events[0].failure_class.?);
    try std.testing.expect(events[0].retained_content);
    try std.testing.expectEqualStrings("unsupported map format", events[0].message);
    try std.testing.expect((try store.tryTileMap(handle)).layers.items.len > 0);
}

test "tile-map dependency reload failures retain the last valid map" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const map = try std.fs.cwd().readFileAlloc(std.testing.allocator, "examples/assets/topdown.upmap", 256 * 1024);
    defer std.testing.allocator.free(map);
    const image = try std.fs.cwd().readFileAlloc(std.testing.allocator, "examples/assets/ball.png", 1024 * 1024);
    defer std.testing.allocator.free(image);
    try tmp.dir.writeFile(.{ .sub_path = "topdown.upmap", .data = map });
    try tmp.dir.writeFile(.{ .sub_path = "ball.png", .data = image });
    var store = AssetStore.init(std.testing.allocator, tmp.dir);
    defer store.deinit();
    const handle = try store.loadTileMap("topdown.upmap", .{});

    var stat = try tmp.dir.statFile("ball.png");
    try tmp.dir.writeFile(.{ .sub_path = "ball.png", .data = "invalid" });
    while ((try tmp.dir.statFile("ball.png")).mtime == stat.mtime) {
        std.Thread.sleep(1_000_000);
        try tmp.dir.writeFile(.{ .sub_path = "ball.png", .data = "invalid" });
        stat = try tmp.dir.statFile("ball.png");
    }

    const events = try store.reloadChanged();
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqual(ReloadStatus.failed, events[0].status);
    try std.testing.expectEqualStrings("topdown.upmap", events[0].path);
    try std.testing.expectEqual(ReloadFailureClass.decode, events[0].failure_class.?);
    try std.testing.expect(events[0].retained_content);
    try std.testing.expect((try store.tryTileMap(handle)).layers.items.len > 0);
}

test "shader assets retain source across reloads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "effect.upshader", .data = "effect=invert\nuniform amount:f32\n" });
    var store = AssetStore.init(std.testing.allocator, tmp.dir);
    defer store.deinit();
    const handle = try store.loadShader("effect.upshader");
    try std.testing.expectEqualStrings("effect=invert\nuniform amount:f32\n", try store.tryShaderSource(handle));

    const stat = try tmp.dir.statFile("effect.upshader");
    std.Thread.sleep(1_100_000_000);
    try tmp.dir.writeFile(.{ .sub_path = "effect.upshader", .data = "effect=blur\n" });
    try std.testing.expect((try tmp.dir.statFile("effect.upshader")).mtime != stat.mtime);
    const changed = try store.reloadChanged();
    try std.testing.expectEqual(@as(usize, 1), changed.len);
    try std.testing.expectEqual(ReloadStatus.changed, changed[0].status);
    try std.testing.expectError(error.StaleHandle, store.tryShaderSource(handle));
    try std.testing.expectEqualStrings("effect=blur\n", try store.latestShaderSource(handle));
}

test "image reload keeps last good asset after invalid edit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const png = try std.fs.cwd().readFileAlloc(std.testing.allocator, "examples/assets/ball.png", 1024 * 1024);
    defer std.testing.allocator.free(png);
    try tmp.dir.writeFile(.{ .sub_path = "ball.png", .data = png });
    var store = AssetStore.init(std.testing.allocator, tmp.dir);
    defer store.deinit();
    const handle = try store.loadImage("ball.png");
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
    try std.testing.expectEqual(ReloadFailureClass.decode, failed[0].failure_class.?);
    try std.testing.expect(failed[0].retained_content);
    try std.testing.expect(failed[0].message.len > 0);
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
    try std.testing.expect((try store.latestImagePtr(handle)).width > 0);
}

test "asset and native map reload fixture retains failures and recovers together" {
    const Fixture = struct {
        fn replace(dir: std.fs.Dir, path: []const u8, bytes: []const u8) !void {
            const previous = try dir.statFile(path);
            while (true) {
                try dir.writeFile(.{ .sub_path = path, .data = bytes });
                if ((try dir.statFile(path)).mtime != previous.mtime) return;
                std.Thread.sleep(1_000_000);
            }
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const map = try std.fs.cwd().readFileAlloc(std.testing.allocator, "examples/assets/topdown.upmap", 256 * 1024);
    defer std.testing.allocator.free(map);
    const image = try std.fs.cwd().readFileAlloc(std.testing.allocator, "examples/assets/ball.png", 1024 * 1024);
    defer std.testing.allocator.free(image);
    try tmp.dir.writeFile(.{ .sub_path = "topdown.upmap", .data = map });
    try tmp.dir.writeFile(.{ .sub_path = "ball.png", .data = image });
    var store = AssetStore.init(std.testing.allocator, tmp.dir);
    defer store.deinit();
    const image_handle = try store.loadImage("ball.png");
    const map_handle = try store.loadTileMap("topdown.upmap", .{});

    try Fixture.replace(tmp.dir, "ball.png", image);
    const refreshed = try store.reloadChanged();
    try std.testing.expectEqual(@as(usize, 2), refreshed.len);
    try std.testing.expectEqual(ReloadStatus.changed, refreshed[0].status);
    try std.testing.expectEqualStrings("ball.png", refreshed[0].path);
    try std.testing.expectEqual(ReloadStatus.changed, refreshed[1].status);
    try std.testing.expectEqualStrings("topdown.upmap", refreshed[1].path);
    try std.testing.expectError(error.StaleHandle, store.tryImage(image_handle));
    try std.testing.expectError(error.StaleHandle, store.tryTileMap(map_handle));
    const refreshed_image = ImageHandle{ .index = image_handle.index, .generation = store.images.items[image_handle.index].generation };
    const refreshed_map = TileMapHandle{ .index = map_handle.index, .generation = store.tile_maps.items[map_handle.index].generation };
    try std.testing.expect((try store.tryImage(refreshed_image)).width > 0);
    try std.testing.expect((try store.tryTileMap(refreshed_map)).layers.items.len > 0);

    try Fixture.replace(tmp.dir, "ball.png", "invalid");
    const failed = try store.reloadChanged();
    try std.testing.expectEqual(@as(usize, 2), failed.len);
    try std.testing.expectEqual(ReloadStatus.failed, failed[0].status);
    try std.testing.expectEqualStrings("ball.png", failed[0].path);
    try std.testing.expectEqual(ReloadFailureClass.decode, failed[0].failure_class.?);
    try std.testing.expect(failed[0].retained_content);
    try std.testing.expectEqual(ReloadStatus.failed, failed[1].status);
    try std.testing.expectEqualStrings("topdown.upmap", failed[1].path);
    try std.testing.expectEqual(ReloadFailureClass.decode, failed[1].failure_class.?);
    try std.testing.expect(failed[1].retained_content);
    try std.testing.expect((try store.tryImage(refreshed_image)).width > 0);
    try std.testing.expect((try store.tryTileMap(refreshed_map)).layers.items.len > 0);

    try Fixture.replace(tmp.dir, "ball.png", image);
    const recovered = try store.reloadChanged();
    try std.testing.expectEqual(@as(usize, 2), recovered.len);
    for (recovered) |event| try std.testing.expectEqual(ReloadStatus.changed, event.status);
    try std.testing.expectError(error.StaleHandle, store.tryImage(refreshed_image));
    try std.testing.expectError(error.StaleHandle, store.tryTileMap(refreshed_map));
}
