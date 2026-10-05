const std = @import("std");
const atlas_mod = @import("atlas.zig");
const Sound = @import("audio.zig").Sound;
const Font = @import("font_asset.zig").Font;
const FontLoadOptions = @import("font_asset.zig").LoadOptions;
const Image = @import("image.zig").Image;
const advanced = @import("advanced_2d.zig");

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
pub const FontHandle = struct { index: usize, generation: u32 }; // borrows an AssetStore entry; use tryFont for stale-handle errors.
pub const MaterialHandle = struct { index: usize, generation: u32 }; // borrows an AssetStore entry; use tryMaterial for stale-handle errors.

pub const AssetStats = struct {
    texts: usize,
    images: usize,
    sounds: usize,
    fonts: usize,
    materials: usize,
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

const MaterialFileSlot = enum(usize) {
    vertex_spirv,
    vertex_dxbc,
    vertex_metallib,
    vertex_webgl2,
    vertex_webgpu,
    fragment_spirv,
    fragment_dxbc,
    fragment_metallib,
    fragment_webgl2,
    fragment_webgpu,
};

const MaterialFileAsset = struct {
    manifest: AssetFile,
    files: [@typeInfo(MaterialFileSlot).@"enum".fields.len]AssetFile,
    bindings: []advanced.ShaderBinding,
    asset: advanced.MaterialAsset,
    generation: u32 = 1,

    fn deinit(self: *MaterialFileAsset) void {
        for (&self.files) |*file| file.deinit();
        self.allocator().free(self.bindings);
        self.manifest.deinit();
        self.* = undefined;
    }

    fn allocator(self: *const MaterialFileAsset) std.mem.Allocator {
        return self.manifest.allocator;
    }

    fn changed(self: *const MaterialFileAsset) !bool {
        if ((try self.manifest.dir.statFile(self.manifest.path)).mtime != self.manifest.mtime) return true;
        for (self.files) |file| if ((try file.dir.statFile(file.path)).mtime != file.mtime) return true;
        return false;
    }
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
    runtime_files_available: bool = true,
    texts: std.ArrayListUnmanaged(TextAsset) = .{},
    images: std.ArrayListUnmanaged(ImageAsset) = .{},
    sounds: std.ArrayListUnmanaged(SoundAsset) = .{},
    fonts: std.ArrayListUnmanaged(FontAsset) = .{},
    materials: std.ArrayListUnmanaged(MaterialFileAsset) = .{},
    events: std.ArrayListUnmanaged(ReloadEvent) = .{},

    pub fn init(allocator: std.mem.Allocator, dir: std.fs.Dir) AssetStore {
        return .{ .allocator = allocator, .dir = dir };
    }

    /// Creates a store for an embedding-only host. Runtime asset loads return
    /// `error.AssetStoreUnavailable`; no working-directory fallback is used.
    fn initEmpty(allocator: std.mem.Allocator) AssetStore {
        return .{ .allocator = allocator, .dir = std.fs.cwd(), .runtime_files_available = false };
    }

    pub fn stats(self: AssetStore) AssetStats {
        return .{
            .texts = self.texts.items.len,
            .images = self.images.items.len,
            .sounds = self.sounds.items.len,
            .fonts = self.fonts.items.len,
            .materials = self.materials.items.len,
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

        return initBesideExecutable(allocator);
    }

    /// Uses an explicitly configured `UP_ASSET_ROOT` when present. When no
    /// runtime asset location is configured or installed beside the executable,
    /// returns an embedding-only store instead of making host startup fail.
    pub fn initExecutableOptional(allocator: std.mem.Allocator) !AssetStore {
        const environment_root = std.process.getEnvVarOwned(allocator, "UP_ASSET_ROOT") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        };
        if (environment_root) |root_path| {
            defer allocator.free(root_path);
            return initAbsolute(allocator, root_path);
        }

        return initBesideExecutable(allocator) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => initEmpty(allocator),
            else => return err,
        };
    }

    fn initBesideExecutable(allocator: std.mem.Allocator) !AssetStore {
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
        for (self.fonts.items) |*asset| asset.deinit();
        for (self.materials.items) |*asset| asset.deinit();
        self.texts.deinit(self.allocator);
        self.images.deinit(self.allocator);
        self.sounds.deinit(self.allocator);
        self.fonts.deinit(self.allocator);
        self.materials.deinit(self.allocator);
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
        try self.requireRuntimeFiles();
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
        try self.requireRuntimeFiles();
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
        try self.requireRuntimeFiles();
        const asset = try self.loadSoundAsset(path);
        errdefer {
            var cleanup = asset;
            cleanup.deinit();
        }
        const index = self.sounds.items.len;
        try self.sounds.append(self.allocator, asset);
        return .{ .index = index, .generation = 1 };
    }

    pub fn loadFont(self: *AssetStore, path: []const u8, options: FontLoadOptions) !FontHandle {
        try self.requireRuntimeFiles();
        const asset = if (std.mem.endsWith(u8, path, ".fnt")) try self.loadBitmapFontAsset(path) else try self.loadFontAsset(path, options);
        errdefer {
            var cleanup = asset;
            cleanup.deinit();
        }
        const index = self.fonts.items.len;
        try self.fonts.append(self.allocator, asset);
        return .{ .index = index, .generation = 1 };
    }

    /// Loads a generated `.upmat` manifest and all ten target-specific stage
    /// artifacts. The material remains valid until this store is deinitialized.
    pub fn loadMaterial(self: *AssetStore, path: []const u8) !MaterialHandle {
        try self.requireRuntimeFiles();
        const asset = try self.loadMaterialAsset(path);
        errdefer {
            var cleanup = asset;
            cleanup.deinit();
        }
        const index = self.materials.items.len;
        try self.materials.append(self.allocator, asset);
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

    pub fn tryMaterial(self: *AssetStore, handle: MaterialHandle) !*const advanced.Material {
        if (handle.index >= self.materials.items.len or self.materials.items[handle.index].generation != handle.generation) return error.StaleHandle;
        return &self.materials.items[handle.index].asset.material;
    }

    pub fn latestMaterial(self: *AssetStore, handle: MaterialHandle) !*const advanced.Material { // accepts stale generations for reload continuity; invalid indexes return error.InvalidHandle.
        if (handle.index >= self.materials.items.len) return error.InvalidHandle;
        return &self.materials.items[handle.index].asset.material;
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

        for (self.fonts.items) |*asset| {
            if (self.reloadFont(asset) catch |err| {
                try self.appendReloadFailure(asset.font_file.path, err, .decode);
                continue;
            }) {
                try self.events.append(self.allocator, .{ .path = asset.font_file.path, .status = .changed });
            }
        }

        for (self.materials.items) |*asset| {
            const changed = asset.changed() catch |err| {
                try self.appendReloadFailure(asset.manifest.path, err, .io);
                continue;
            };
            if (!changed) continue;
            const next = self.loadMaterialAsset(asset.manifest.path) catch |err| {
                try self.appendReloadFailure(asset.manifest.path, err, .source);
                continue;
            };
            const generation = nextGeneration(asset.generation);
            const revision = nextGeneration(asset.asset.revision);
            asset.deinit();
            asset.* = next;
            asset.generation = generation;
            asset.asset.revision = revision;
            asset.asset.material.revision = revision;
            try self.events.append(self.allocator, .{ .path = asset.manifest.path, .status = .changed });
        }

        return self.events.items;
    }

    fn appendReloadFailure(self: *AssetStore, path: []const u8, err: anyerror, failure_class: ReloadFailureClass) !void {
        try self.appendReloadFailureWithLocation(path, err, failure_class, 1, 1, @errorName(err));
    }

    fn requireRuntimeFiles(self: AssetStore) !void {
        if (!self.runtime_files_available) return error.AssetStoreUnavailable;
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
        if (!std.mem.endsWith(u8, path, ".wav") and !std.mem.endsWith(u8, path, ".ogg")) return error.UnsupportedSoundAsset;
        const file = try AssetFile.load(self.allocator, self.dir, path, @import("audio.zig").stable_max_input_bytes);
        errdefer {
            var cleanup = file;
            cleanup.deinit();
        }
        const decoded = if (std.mem.endsWith(u8, path, ".wav")) try Sound.decodeWav(self.allocator, file.bytes) else try Sound.decodeOgg(self.allocator, file.bytes);
        errdefer {
            var cleanup = decoded;
            cleanup.deinit();
        }
        return .{ .file = file, .sound = decoded };
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

    fn loadMaterialAsset(self: *AssetStore, path: []const u8) !MaterialFileAsset {
        var manifest = try AssetFile.load(self.allocator, self.dir, path, 256 * 1024);
        errdefer manifest.deinit();
        const name = try materialManifestValue(manifest.bytes, "name");
        const binding_specs = try materialManifestBindings(self.allocator, manifest.bytes);
        errdefer self.allocator.free(binding_specs);
        var files: [@typeInfo(MaterialFileSlot).@"enum".fields.len]AssetFile = undefined;
        var loaded: usize = 0;
        errdefer for (files[0..loaded]) |*file| file.deinit();
        inline for (std.meta.fields(MaterialFileSlot)) |field| {
            const slot: MaterialFileSlot = @enumFromInt(field.value);
            const key = materialManifestKey(slot);
            const source = try materialManifestValue(manifest.bytes, key);
            const resolved = try atlas_mod.resolveSiblingPath(self.allocator, path, source);
            defer self.allocator.free(resolved);
            files[@intFromEnum(slot)] = try AssetFile.load(self.allocator, self.dir, resolved, advanced.max_native_shader_bytes);
            loaded += 1;
        }
        const stages = advanced.MaterialStages{
            .vertex = .{
                .native = .{ .spirv = files[@intFromEnum(MaterialFileSlot.vertex_spirv)].bytes, .dxbc = files[@intFromEnum(MaterialFileSlot.vertex_dxbc)].bytes, .metallib = files[@intFromEnum(MaterialFileSlot.vertex_metallib)].bytes },
                .webgl2_glsl_es = files[@intFromEnum(MaterialFileSlot.vertex_webgl2)].bytes,
                .webgpu_wgsl = files[@intFromEnum(MaterialFileSlot.vertex_webgpu)].bytes,
            },
            .fragment = .{
                .native = .{ .spirv = files[@intFromEnum(MaterialFileSlot.fragment_spirv)].bytes, .dxbc = files[@intFromEnum(MaterialFileSlot.fragment_dxbc)].bytes, .metallib = files[@intFromEnum(MaterialFileSlot.fragment_metallib)].bytes },
                .webgl2_glsl_es = files[@intFromEnum(MaterialFileSlot.fragment_webgl2)].bytes,
                .webgpu_wgsl = files[@intFromEnum(MaterialFileSlot.fragment_webgpu)].bytes,
            },
            .bindings = binding_specs,
        };
        const material = try advanced.Material.initStages(name, stages);
        return .{ .manifest = manifest, .files = files, .bindings = binding_specs, .asset = .{ .material = material } };
    }
};

fn materialManifestKey(slot: MaterialFileSlot) []const u8 {
    return switch (slot) {
        .vertex_spirv => "vertex.spirv",
        .vertex_dxbc => "vertex.dxbc",
        .vertex_metallib => "vertex.metallib",
        .vertex_webgl2 => "vertex.webgl2",
        .vertex_webgpu => "vertex.webgpu",
        .fragment_spirv => "fragment.spirv",
        .fragment_dxbc => "fragment.dxbc",
        .fragment_metallib => "fragment.metallib",
        .fragment_webgl2 => "fragment.webgl2",
        .fragment_webgpu => "fragment.webgpu",
    };
}

fn materialManifestValue(bytes: []const u8, key: []const u8) ![]const u8 {
    var found: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const equals = std.mem.indexOfScalar(u8, trimmed, '=') orelse return error.InvalidMaterialManifest;
        const current_key = std.mem.trim(u8, trimmed[0..equals], " \t");
        if (!std.mem.eql(u8, current_key, key)) continue;
        if (found != null) return error.DuplicateMaterialManifestKey;
        const value = std.mem.trim(u8, trimmed[equals + 1 ..], " \t");
        if (value.len == 0) return error.InvalidMaterialManifest;
        found = value;
    }
    return found orelse error.MissingMaterialManifestKey;
}

fn materialManifestBindings(allocator: std.mem.Allocator, bytes: []const u8) ![]advanced.ShaderBinding {
    var result: std.ArrayListUnmanaged(advanced.ShaderBinding) = .{};
    errdefer result.deinit(allocator);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const equals = std.mem.indexOfScalar(u8, trimmed, '=') orelse return error.InvalidMaterialManifest;
        if (!std.mem.eql(u8, std.mem.trim(u8, trimmed[0..equals], " \t"), "binding")) continue;
        const value = std.mem.trim(u8, trimmed[equals + 1 ..], " \t");
        const colon = std.mem.indexOfScalar(u8, value, ':') orelse return error.InvalidMaterialBinding;
        const kind = std.mem.trim(u8, value[0..colon], " \t");
        const name = std.mem.trim(u8, value[colon + 1 ..], " \t");
        const binding_kind: advanced.ShaderBindingKind = if (std.mem.eql(u8, kind, "texture")) .texture else if (std.mem.eql(u8, kind, "uniform")) .uniform else return error.InvalidMaterialBinding;
        try result.append(allocator, .{ .name = name, .kind = binding_kind });
    }
    if (result.items.len == 0) return error.InvalidMaterialBindings;
    return try result.toOwnedSlice(allocator);
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
    const ogg = try store.loadSound("examples/assets/tone.ogg");
    const truetype = try store.loadFont("examples/assets/fonts/Basic-Regular.ttf", .{});
    const opentype = try store.loadFont("examples/assets/fonts/SourceSans3-Regular.otf", .{});
    const bitmap = try store.loadFont("examples/assets/fonts/bitmap.fnt", .{});
    try std.testing.expect((try store.tryText(text)).len > 0);
    try std.testing.expect((try store.tryImage(image)).width > 0);
    try std.testing.expect((try store.trySound(sound)).frames.len > 0);
    try std.testing.expect((try store.trySound(ogg)).frames.len > 0);
    try std.testing.expect((try store.tryFont(truetype)).glyphForCodepoint(0x00c9).?.width > 0);
    try std.testing.expect((try store.tryFont(opentype)).glyphForCodepoint(0x00c9).?.width > 0);
    try std.testing.expect((try store.tryFont(bitmap)).glyphForCodepoint('B').?.width > 0);
    try std.testing.expectError(error.StaleHandle, store.tryText(.{ .index = text.index, .generation = nextGeneration(text.generation) }));
    try std.testing.expectError(error.StaleHandle, store.tryImage(.{ .index = image.index, .generation = nextGeneration(image.generation) }));
    try std.testing.expectError(error.StaleHandle, store.trySound(.{ .index = sound.index, .generation = nextGeneration(sound.generation) }));
    try std.testing.expectError(error.StaleHandle, store.tryFont(.{ .index = truetype.index, .generation = nextGeneration(truetype.generation) }));
    try std.testing.expectError(error.StaleHandle, store.tryFont(.{ .index = opentype.index, .generation = nextGeneration(opentype.generation) }));
}

test "asset store exposes canonical loaders only" {
    try std.testing.expect(@hasDecl(AssetStore, "loadImage"));
    try std.testing.expect(@hasDecl(AssetStore, "loadFont"));
    try std.testing.expect(@hasDecl(AssetStore, "loadSound"));
    try std.testing.expect(@hasDecl(AssetStore, "loadMaterial"));
    try std.testing.expect(!@hasDecl(AssetStore, "loadAtlas"));
    try std.testing.expect(!@hasDecl(AssetStore, "loadPng"));
    try std.testing.expect(!@hasDecl(AssetStore, "loadBitmapFont"));
    try std.testing.expect(!@hasDecl(AssetStore, "loadFontWithOptions"));
}

test "an embedding-only asset store never falls back to the working directory" {
    var store = AssetStore.initEmpty(std.testing.allocator);
    defer store.deinit();
    try std.testing.expectError(error.AssetStoreUnavailable, store.loadText("examples/assets/message.txt"));
    try std.testing.expectError(error.AssetStoreUnavailable, store.loadImage("examples/assets/ball.png"));
    try std.testing.expectError(error.AssetRootUnavailable, store.assetPath(std.testing.allocator, "ball.png"));
    try std.testing.expectEqual(@as(usize, 0), (try store.reloadChanged()).len);
}

test "material manifests create staged assets with reserved source binding" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const entries = [_]struct { name: []const u8, bytes: []const u8 }{
        .{ .name = "vertex.spv", .bytes = "x" }, .{ .name = "vertex.dxbc", .bytes = "x" }, .{ .name = "vertex.metallib", .bytes = "x" }, .{ .name = "vertex.glsl", .bytes = "void main(){}" }, .{ .name = "vertex.wgsl", .bytes = "fn main() {}" },
        .{ .name = "fragment.spv", .bytes = "x" }, .{ .name = "fragment.dxbc", .bytes = "x" }, .{ .name = "fragment.metallib", .bytes = "x" }, .{ .name = "fragment.glsl", .bytes = "void main(){}" }, .{ .name = "fragment.wgsl", .bytes = "fn main() {}" },
    };
    for (entries) |entry| try tmp.dir.writeFile(.{ .sub_path = entry.name, .data = entry.bytes });
    try tmp.dir.writeFile(.{ .sub_path = "wave.upmat", .data =
        "name=wave\n" ++
            "vertex.spirv=vertex.spv\nvertex.dxbc=vertex.dxbc\nvertex.metallib=vertex.metallib\nvertex.webgl2=vertex.glsl\nvertex.webgpu=vertex.wgsl\n" ++
            "fragment.spirv=fragment.spv\nfragment.dxbc=fragment.dxbc\nfragment.metallib=fragment.metallib\nfragment.webgl2=fragment.glsl\nfragment.webgpu=fragment.wgsl\n" ++
            "binding=texture:source\nbinding=uniform:settings\n" });
    var store = AssetStore.init(std.testing.allocator, tmp.dir);
    defer store.deinit();
    const handle = try store.loadMaterial("wave.upmat");
    const material = try store.tryMaterial(handle);
    try std.testing.expectEqualStrings("wave", material.name);
    try std.testing.expectEqual(@as(usize, 2), (try material.executableStages()).bindings.len);
    try std.testing.expectError(error.StaleHandle, store.tryMaterial(.{ .index = handle.index, .generation = nextGeneration(handle.generation) }));

    const revision = material.revision;
    const fragment_mtime = (try tmp.dir.statFile("fragment.glsl")).mtime;
    try tmp.dir.writeFile(.{ .sub_path = "fragment.glsl", .data = "void main(){ }" });
    while ((try tmp.dir.statFile("fragment.glsl")).mtime == fragment_mtime) {
        std.Thread.sleep(1_000_000);
        try tmp.dir.writeFile(.{ .sub_path = "fragment.glsl", .data = "void main(){ }" });
    }
    const reloaded = try store.reloadChanged();
    try std.testing.expectEqual(ReloadStatus.changed, reloaded[0].status);
    try std.testing.expectError(error.StaleHandle, store.tryMaterial(handle));
    try std.testing.expectEqual(nextGeneration(revision), (try store.latestMaterial(handle)).revision);

    const manifest_mtime = (try tmp.dir.statFile("wave.upmat")).mtime;
    try tmp.dir.writeFile(.{ .sub_path = "wave.upmat", .data = "name=broken\n" });
    while ((try tmp.dir.statFile("wave.upmat")).mtime == manifest_mtime) {
        std.Thread.sleep(1_000_000);
        try tmp.dir.writeFile(.{ .sub_path = "wave.upmat", .data = "name=broken\n" });
    }
    const failed = try store.reloadChanged();
    try std.testing.expectEqual(ReloadStatus.failed, failed[0].status);
    try std.testing.expect(failed[0].retained_content);
    try std.testing.expectEqual(nextGeneration(revision), (try store.latestMaterial(handle)).revision);
}

test "asset store exposes checked handle accessors" {
    try std.testing.expect(@hasDecl(AssetStore, "tryText"));
    try std.testing.expect(@hasDecl(AssetStore, "tryImage"));
    try std.testing.expect(@hasDecl(AssetStore, "tryImagePtr"));
    try std.testing.expect(@hasDecl(AssetStore, "tryFont"));
    try std.testing.expect(@hasDecl(AssetStore, "tryFontPtr"));
    try std.testing.expect(!@hasDecl(AssetStore, "tryAtlas"));
    try std.testing.expect(!@hasDecl(AssetStore, "text"));
    try std.testing.expect(!@hasDecl(AssetStore, "image"));
    try std.testing.expect(!@hasDecl(AssetStore, "imagePtr"));
    try std.testing.expect(!@hasDecl(AssetStore, "font"));
    try std.testing.expect(!@hasDecl(AssetStore, "fontPtr"));
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
