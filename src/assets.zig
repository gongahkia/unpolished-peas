const std = @import("std");
const atlas_mod = @import("atlas.zig");
const Sound = @import("audio.zig").Sound;
const Font = @import("font_asset.zig").Font;
const FontLoadOptions = @import("font_asset.zig").LoadOptions;
const Image = @import("image.zig").Image;

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
pub const ShaderAssetHandle = struct { index: usize, generation: u32 }; // borrows an AssetStore entry; use tryShaderSource for stale-handle errors.

pub const AssetStats = struct {
    texts: usize,
    images: usize,
    sounds: usize,
    fonts: usize,
    shaders: usize,
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

const ShaderAsset = struct {
    file: AssetFile,
    generation: u32 = 1,

    fn deinit(self: *ShaderAsset) void {
        self.file.deinit();
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
    texts: std.ArrayListUnmanaged(TextAsset) = .{},
    images: std.ArrayListUnmanaged(ImageAsset) = .{},
    sounds: std.ArrayListUnmanaged(SoundAsset) = .{},
    fonts: std.ArrayListUnmanaged(FontAsset) = .{},
    shaders: std.ArrayListUnmanaged(ShaderAsset) = .{},
    events: std.ArrayListUnmanaged(ReloadEvent) = .{},

    pub fn init(allocator: std.mem.Allocator, dir: std.fs.Dir) AssetStore {
        return .{ .allocator = allocator, .dir = dir };
    }

    pub fn stats(self: AssetStore) AssetStats {
        return .{
            .texts = self.texts.items.len,
            .images = self.images.items.len,
            .sounds = self.sounds.items.len,
            .fonts = self.fonts.items.len,
            .shaders = self.shaders.items.len,
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
        for (self.fonts.items) |*asset| asset.deinit();
        for (self.shaders.items) |*asset| asset.deinit();
        self.texts.deinit(self.allocator);
        self.images.deinit(self.allocator);
        self.sounds.deinit(self.allocator);
        self.fonts.deinit(self.allocator);
        self.shaders.deinit(self.allocator);
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

    pub fn tryShaderSource(self: AssetStore, handle: ShaderAssetHandle) ![]const u8 {
        if (handle.index >= self.shaders.items.len or self.shaders.items[handle.index].generation != handle.generation) return error.StaleHandle;
        return self.shaders.items[handle.index].file.text();
    }

    pub fn latestShaderSource(self: AssetStore, handle: ShaderAssetHandle) ![]const u8 {
        if (handle.index >= self.shaders.items.len) return error.InvalidHandle;
        return self.shaders.items[handle.index].file.text();
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

        for (self.shaders.items) |*asset| {
            if (self.reloadShader(asset) catch |err| {
                try self.appendReloadFailure(asset.file.path, err, .io);
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
    const image = try store.loadImage("examples/assets/ball.png");
    const sound = try store.loadSound("examples/assets/blip.wav");
    const truetype = try store.loadFont("examples/assets/fonts/Basic-Regular.ttf", .{});
    const opentype = try store.loadFont("examples/assets/fonts/SourceSans3-Regular.otf", .{});
    const bitmap = try store.loadFont("examples/assets/fonts/bitmap.fnt", .{});
    try std.testing.expect((try store.tryText(text)).len > 0);
    try std.testing.expect((try store.tryImage(image)).width > 0);
    try std.testing.expect((try store.trySound(sound)).frames.len > 0);
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
    try std.testing.expect(!@hasDecl(AssetStore, "loadAtlas"));
    try std.testing.expect(!@hasDecl(AssetStore, "loadTileMap"));
    try std.testing.expect(!@hasDecl(AssetStore, "loadPng"));
    try std.testing.expect(!@hasDecl(AssetStore, "loadBitmapFont"));
    try std.testing.expect(!@hasDecl(AssetStore, "loadFontWithOptions"));
}

test "asset store exposes checked handle accessors" {
    try std.testing.expect(@hasDecl(AssetStore, "tryText"));
    try std.testing.expect(@hasDecl(AssetStore, "tryImage"));
    try std.testing.expect(@hasDecl(AssetStore, "tryImagePtr"));
    try std.testing.expect(@hasDecl(AssetStore, "tryFont"));
    try std.testing.expect(@hasDecl(AssetStore, "tryFontPtr"));
    try std.testing.expect(!@hasDecl(AssetStore, "tryAtlas"));
    try std.testing.expect(!@hasDecl(AssetStore, "tryTileMap"));
    try std.testing.expect(!@hasDecl(AssetStore, "text"));
    try std.testing.expect(!@hasDecl(AssetStore, "image"));
    try std.testing.expect(!@hasDecl(AssetStore, "imagePtr"));
    try std.testing.expect(!@hasDecl(AssetStore, "font"));
    try std.testing.expect(!@hasDecl(AssetStore, "fontPtr"));
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
