const std = @import("std");
const up = @import("unpolished-peas");

/// Native developer-only reload support for authored assets that are embedded
/// in release builds. It deliberately owns no game resources: callers retain
/// ownership of their Atlas and Font values, while this registry swaps a fully
/// decoded replacement at a presentation-frame boundary.
pub const Registry = struct {
    pub const poll_interval_ns: i128 = 250 * std.time.ns_per_ms;

    allocator: std.mem.Allocator,
    enabled: bool,
    source_dir: ?std.fs.Dir = null,
    source_root: ?[]u8 = null,
    entries: std.ArrayListUnmanaged(Entry) = .{},
    events: std.ArrayListUnmanaged(up.assets.ReloadEvent) = .{},
    reloads_total: u32 = 0,
    reload_failures: u32 = 0,
    last_asset: []const u8 = "",
    last_result: Result = .none,
    last_poll_ns: ?i128 = null,

    pub const Result = enum {
        none,
        changed,
        failed,
    };

    pub const Stats = struct {
        enabled: bool,
        registered: usize,
        reloads_total: u32,
        reload_failures: u32,
        last_asset: []const u8,
        last_result: Result,
    };

    /// `UP_DEVELOPER_ASSET_ROOT` must be an explicit absolute directory. If it
    /// is absent, this is an inert registry: release/normal development runs
    /// neither inspect the working directory nor allocate registered entries.
    pub fn init(allocator: std.mem.Allocator, developer_tools_enabled: bool) !Registry {
        if (!developer_tools_enabled) return .{ .allocator = allocator, .enabled = false };

        const source_root = std.process.getEnvVarOwned(allocator, "UP_DEVELOPER_ASSET_ROOT") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => return .{ .allocator = allocator, .enabled = false },
            else => return err,
        };
        errdefer allocator.free(source_root);
        if (!std.fs.path.isAbsolute(source_root)) return error.DeveloperAssetRootMustBeAbsolute;
        const source_dir = try std.fs.openDirAbsolute(source_root, .{});
        return .{
            .allocator = allocator,
            .enabled = true,
            .source_dir = source_dir,
            .source_root = source_root,
        };
    }

    /// Test-only explicit-root constructor. Production source roots always use
    /// `UP_DEVELOPER_ASSET_ROOT` so there is no accidental CWD fallback.
    pub fn initForTesting(allocator: std.mem.Allocator, source_root: []const u8, enabled: bool) !Registry {
        if (!enabled) return .{ .allocator = allocator, .enabled = false };
        if (!std.fs.path.isAbsolute(source_root)) return error.DeveloperAssetRootMustBeAbsolute;
        const owned_root = try allocator.dupe(u8, source_root);
        errdefer allocator.free(owned_root);
        const source_dir = try std.fs.openDirAbsolute(owned_root, .{});
        return .{ .allocator = allocator, .enabled = true, .source_dir = source_dir, .source_root = owned_root };
    }

    pub fn deinit(self: *Registry) void {
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.events.deinit(self.allocator);
        if (self.source_root) |root| self.allocator.free(root);
        if (self.source_dir) |*dir| dir.close();
        self.* = undefined;
    }

    pub fn stats(self: *const Registry) Stats {
        return .{
            .enabled = self.enabled,
            .registered = self.entries.items.len,
            .reloads_total = self.reloads_total,
            .reload_failures = self.reload_failures,
            .last_asset = self.last_asset,
            .last_result = self.last_result,
        };
    }

    /// Registers an Atlas-owned image. The atlas must outlive this registry.
    /// A replacement with dimensions incompatible with its existing frames is
    /// rejected and leaves the current image untouched.
    pub fn registerAtlasImage(self: *Registry, atlas: *up.assets.Atlas, source_path: []const u8, options: up.assets.ImageDecodeOptions) !bool {
        if (!self.enabled) return false;
        try validateSourcePath(source_path);
        try self.rejectDuplicate(.{ .resource = .{ .atlas_image = .{ .atlas = atlas, .path = undefined, .options = options, .applied = undefined } } });
        const path = try self.allocator.dupe(u8, source_path);
        errdefer self.allocator.free(path);
        const observed_signature = try self.signature(path);
        try self.entries.append(self.allocator, .{ .resource = .{ .atlas_image = .{
            .atlas = atlas,
            .path = path,
            .options = options,
            .applied = observed_signature,
        } } });
        return true;
    }

    /// Registers a TrueType/OpenType font. The font must outlive this registry.
    /// Font range options are copied so the game may use a temporary options
    /// slice during registration.
    pub fn registerFont(self: *Registry, font: *up.assets.Font, source_path: []const u8, options: up.assets.FontLoadOptions) !bool {
        if (!self.enabled) return false;
        try validateSourcePath(source_path);
        try self.rejectDuplicate(.{ .resource = .{ .font = .{ .font = font, .path = undefined, .options = options, .owned_ranges = null, .applied = undefined } } });
        const path = try self.allocator.dupe(u8, source_path);
        errdefer self.allocator.free(path);
        const owned_ranges = if (options.ranges.len == 0) null else try self.allocator.dupe(up.graphics.FontGlyphRange, options.ranges);
        errdefer if (owned_ranges) |ranges| self.allocator.free(ranges);
        var stored_options = options;
        if (owned_ranges) |ranges| stored_options.ranges = ranges;
        const observed_signature = try self.signature(path);
        try self.entries.append(self.allocator, .{ .resource = .{ .font = .{
            .font = font,
            .path = path,
            .options = stored_options,
            .owned_ranges = owned_ranges,
            .applied = observed_signature,
        } } });
        return true;
    }

    /// Polls no more than once every quarter second. This is deliberately
    /// presentation-frame work, never a fixed-update or draw-call hook.
    pub fn poll(self: *Registry) ![]const up.assets.ReloadEvent {
        if (!self.enabled or self.entries.items.len == 0) return &.{};
        const now = std.time.nanoTimestamp();
        if (self.last_poll_ns) |previous| if (now - previous < poll_interval_ns) return &.{};
        self.last_poll_ns = now;
        return self.pollOnce();
    }

    /// Deterministic test hook that bypasses wall-clock throttling while
    /// retaining the same metadata/debounce/replacement behavior.
    pub fn pollForTesting(self: *Registry) ![]const up.assets.ReloadEvent {
        if (!self.enabled or self.entries.items.len == 0) return &.{};
        return self.pollOnce();
    }

    fn pollOnce(self: *Registry) ![]const up.assets.ReloadEvent {
        self.events.clearRetainingCapacity();
        for (self.entries.items) |*entry| try self.pollEntry(entry);
        return self.events.items;
    }

    fn pollEntry(self: *Registry, entry: *Entry) !void {
        const path = entry.path();
        const observed = self.signature(path) catch |err| {
            if (entry.last_io_error == null or entry.last_io_error.? != err) try self.appendFailure(path, err);
            entry.last_io_error = err;
            return;
        };
        entry.last_io_error = null;
        if (Signature.eql(observed, entry.applied())) {
            entry.pending = null;
            entry.failed = null;
            return;
        }
        if (entry.failed) |failed| if (Signature.eql(observed, failed)) return;
        if (entry.pending == null or !Signature.eql(observed, entry.pending.?)) {
            entry.pending = observed;
            return;
        }

        entry.pending = null;
        self.replace(entry) catch |err| {
            entry.failed = observed;
            try self.appendFailure(path, err);
            return;
        };
        entry.setApplied(observed);
        entry.failed = null;
        try self.events.append(self.allocator, .{ .path = path, .status = .changed });
        self.reloads_total +|= 1;
        self.last_asset = path;
        self.last_result = .changed;
    }

    fn replace(self: *Registry, entry: *Entry) !void {
        const dir = self.source_dir orelse return error.DeveloperAssetReloadUnavailable;
        const path = entry.path();
        switch (entry.resource) {
            .atlas_image => |*image| {
                const bytes = try dir.readFileAlloc(self.allocator, path, image.options.max_input_bytes);
                defer self.allocator.free(bytes);
                var decoded = try up.assets.Image.decode(self.allocator, bytes, image.options);
                errdefer decoded.deinit();
                try validateAtlasImage(image.atlas, decoded);
                const previous = image.atlas.image;
                image.atlas.image = decoded;
                var old = previous;
                old.deinit();
            },
            .font => |*font| {
                const bytes = try dir.readFileAlloc(self.allocator, path, 32 * 1024 * 1024);
                defer self.allocator.free(bytes);
                var decoded = try up.assets.Font.decodeTrueType(self.allocator, bytes, font.options);
                errdefer decoded.deinit();
                const previous = font.font.*;
                font.font.* = decoded;
                var old = previous;
                old.deinit();
            },
        }
    }

    fn appendFailure(self: *Registry, path: []const u8, err: anyerror) !void {
        try self.events.append(self.allocator, .{
            .path = path,
            .status = .failed,
            .err = err,
            // `ReloadFailureClass` is intentionally not part of the frozen
            // public asset namespace. The developer registry preserves the
            // exact error string instead of widening that stable surface.
            .failure_class = null,
            .retained_content = true,
            .message = @errorName(err),
        });
        self.reload_failures +|= 1;
        self.last_asset = path;
        self.last_result = .failed;
    }

    fn signature(self: *const Registry, path: []const u8) !Signature {
        const dir = self.source_dir orelse return error.DeveloperAssetReloadUnavailable;
        const stat = try dir.statFile(path);
        return .{ .mtime = stat.mtime, .size = stat.size };
    }

    fn rejectDuplicate(self: *const Registry, candidate: Entry) !void {
        for (self.entries.items) |entry| {
            if (entry.sameTarget(candidate)) return error.DuplicateDeveloperAsset;
        }
    }
};

/// The SDL host activates a registry only around a game `init` callback. This
/// gives a game an explicit setup point without adding a field to the frozen
/// `GameContext` or retaining a global developer service through gameplay.
var active_registry: ?*Registry = null;

pub fn activateForGameInit(registry: ?*Registry) void {
    active_registry = registry;
}

/// Experimental native-developer helper. Calling it outside SDL game
/// initialization, without `UP_DEVELOPER_ASSET_ROOT`, is a successful no-op.
pub fn registerAtlasImage(atlas: *up.assets.Atlas, source_path: []const u8, options: up.assets.ImageDecodeOptions) !bool {
    const registry = active_registry orelse return false;
    return registry.registerAtlasImage(atlas, source_path, options);
}

/// Experimental native-developer helper. See `registerAtlasImage`.
pub fn registerFont(font: *up.assets.Font, source_path: []const u8, options: up.assets.FontLoadOptions) !bool {
    const registry = active_registry orelse return false;
    return registry.registerFont(font, source_path, options);
}

const Signature = struct {
    mtime: i128,
    size: u64,

    fn eql(a: Signature, b: Signature) bool {
        return a.mtime == b.mtime and a.size == b.size;
    }
};

const AtlasImageEntry = struct {
    atlas: *up.assets.Atlas,
    path: []u8,
    options: up.assets.ImageDecodeOptions,
    applied: Signature,
};

const FontEntry = struct {
    font: *up.assets.Font,
    path: []u8,
    options: up.assets.FontLoadOptions,
    owned_ranges: ?[]up.graphics.FontGlyphRange,
    applied: Signature,
};

const Entry = struct {
    resource: union(enum) {
        atlas_image: AtlasImageEntry,
        font: FontEntry,
    },
    pending: ?Signature = null,
    failed: ?Signature = null,
    last_io_error: ?anyerror = null,

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        switch (self.resource) {
            .atlas_image => |image| allocator.free(image.path),
            .font => |font| {
                allocator.free(font.path);
                if (font.owned_ranges) |ranges| allocator.free(ranges);
            },
        }
    }

    fn path(self: *const Entry) []const u8 {
        return switch (self.resource) {
            .atlas_image => |image| image.path,
            .font => |font| font.path,
        };
    }

    fn applied(self: *const Entry) Signature {
        return switch (self.resource) {
            .atlas_image => |image| image.applied,
            .font => |font| font.applied,
        };
    }

    fn setApplied(self: *Entry, signature: Signature) void {
        switch (self.resource) {
            .atlas_image => |*image| image.applied = signature,
            .font => |*font| font.applied = signature,
        }
    }

    fn sameTarget(self: Entry, other: Entry) bool {
        return switch (self.resource) {
            .atlas_image => |image| switch (other.resource) {
                .atlas_image => |candidate| image.atlas == candidate.atlas,
                else => false,
            },
            .font => |font| switch (other.resource) {
                .font => |candidate| font.font == candidate.font,
                else => false,
            },
        };
    }
};

fn validateSourcePath(path: []const u8) !void {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return error.InvalidDeveloperAssetPath;
    var components = std.mem.tokenizeAny(u8, path, "/\\");
    var depth: usize = 0;
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) {
            if (depth == 0) return error.InvalidDeveloperAssetPath;
            depth -= 1;
        } else depth += 1;
    }
    if (depth == 0) return error.InvalidDeveloperAssetPath;
}

fn validateAtlasImage(atlas: *const up.assets.Atlas, image: up.assets.Image) !void {
    for (atlas.frames) |frame| {
        const right = std.math.add(i32, frame.x, frame.w) catch return error.InvalidAtlasFrame;
        const bottom = std.math.add(i32, frame.y, frame.h) catch return error.InvalidAtlasFrame;
        if (frame.x < 0 or frame.y < 0 or frame.w <= 0 or frame.h <= 0 or right > @as(i32, @intCast(image.width)) or bottom > @as(i32, @intCast(image.height))) return error.InvalidAtlasFrame;
    }
}

fn tga(width: u16, height: u16, b: u8, g: u8, r: u8) [21]u8 {
    var bytes = [_]u8{0} ** 21;
    bytes[2] = 2;
    bytes[12] = @truncate(width);
    bytes[13] = @truncate(width >> 8);
    bytes[14] = @truncate(height);
    bytes[15] = @truncate(height >> 8);
    bytes[16] = 24;
    bytes[17] = 0x20;
    bytes[18] = b;
    bytes[19] = g;
    bytes[20] = r;
    return bytes;
}

fn writeTga(dir: std.fs.Dir, name: []const u8, color: [3]u8) !void {
    try dir.writeFile(.{ .sub_path = name, .data = &tga(1, 1, color[2], color[1], color[0]) });
}

test "developer image reload debounces, retains invalid content, and recovers" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try writeTga(temp.dir, "sprite.tga", .{ 255, 0, 0 });
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    const initial_bytes = try temp.dir.readFileAlloc(std.testing.allocator, "sprite.tga", 1024);
    defer std.testing.allocator.free(initial_bytes);
    const initial_image = try up.assets.Image.decode(std.testing.allocator, initial_bytes, .{});
    var atlas = try up.assets.Atlas.init(std.testing.allocator, initial_image, "sprite.tga", &.{.{ .name = "sprite", .x = 0, .y = 0, .w = 1, .h = 1 }}, &.{});
    defer atlas.deinit();
    var registry = try Registry.initForTesting(std.testing.allocator, root, true);
    defer registry.deinit();
    _ = try registry.registerAtlasImage(&atlas, "sprite.tga", .{});

    var replacement = [_]u8{0} ** 22;
    @memcpy(replacement[0..21], &tga(1, 1, 0, 255, 0));
    replacement[21] = 0;
    try temp.dir.writeFile(.{ .sub_path = "replacement.tga", .data = &replacement });
    try temp.dir.rename("replacement.tga", "sprite.tga");
    try std.testing.expectEqual(@as(usize, 0), (try registry.pollForTesting()).len);
    const changed = try registry.pollForTesting();
    try std.testing.expectEqual(@as(usize, 1), changed.len);
    try std.testing.expectEqual(up.assets.ReloadStatus.changed, changed[0].status);
    try std.testing.expectEqual(up.core.Color.rgb(0, 255, 0), atlas.image.pixels[0]);

    try temp.dir.writeFile(.{ .sub_path = "sprite.tga", .data = "broken image bytes" });
    _ = try registry.pollForTesting();
    const failed = try registry.pollForTesting();
    try std.testing.expectEqual(@as(usize, 1), failed.len);
    try std.testing.expectEqual(up.assets.ReloadStatus.failed, failed[0].status);
    try std.testing.expect(failed[0].retained_content);
    try std.testing.expectEqual(up.core.Color.rgb(0, 255, 0), atlas.image.pixels[0]);

    try writeTga(temp.dir, "sprite.tga", .{ 0, 0, 255 });
    _ = try registry.pollForTesting();
    const recovered = try registry.pollForTesting();
    try std.testing.expectEqual(up.assets.ReloadStatus.changed, recovered[0].status);
    try std.testing.expectEqual(up.core.Color.rgb(0, 0, 255), atlas.image.pixels[0]);
    try std.testing.expectEqual(@as(u32, 2), registry.stats().reloads_total);
    try std.testing.expectEqual(@as(u32, 1), registry.stats().reload_failures);
}

test "developer font reload retains a valid font and recovers" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const font_bytes = try std.fs.cwd().readFileAlloc(std.testing.allocator, "dogfood/neon-siege/assets/neon-siege.ttf", 1024 * 1024);
    defer std.testing.allocator.free(font_bytes);
    try temp.dir.writeFile(.{ .sub_path = "ui.ttf", .data = font_bytes });
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    var font = try up.assets.Font.decodeTrueType(std.testing.allocator, font_bytes, .{ .pixel_height = 8, .atlas_width = 128, .atlas_height = 128 });
    defer font.deinit();
    var registry = try Registry.initForTesting(std.testing.allocator, root, true);
    defer registry.deinit();
    _ = try registry.registerFont(&font, "ui.ttf", .{ .pixel_height = 8, .atlas_width = 128, .atlas_height = 128 });

    try temp.dir.writeFile(.{ .sub_path = "ui.ttf", .data = "invalid font" });
    _ = try registry.pollForTesting();
    const failed = try registry.pollForTesting();
    try std.testing.expectEqual(up.assets.ReloadStatus.failed, failed[0].status);
    try std.testing.expect(font.glyphForCodepoint('N') != null);

    const padded = try std.testing.allocator.alloc(u8, font_bytes.len + 1);
    defer std.testing.allocator.free(padded);
    @memcpy(padded[0..font_bytes.len], font_bytes);
    padded[font_bytes.len] = 0;
    try temp.dir.writeFile(.{ .sub_path = "ui.ttf", .data = padded });
    _ = try registry.pollForTesting();
    const recovered = try registry.pollForTesting();
    try std.testing.expectEqual(up.assets.ReloadStatus.changed, recovered[0].status);
    try std.testing.expect(font.glyphForCodepoint('N') != null);
}

test "disabled developer registry does not retain source entries" {
    var registry = try Registry.initForTesting(std.testing.allocator, "/", false);
    defer registry.deinit();
    try std.testing.expect(!registry.enabled);
    try std.testing.expectEqual(@as(usize, 0), (try registry.pollForTesting()).len);
    try std.testing.expectError(error.InvalidDeveloperAssetPath, validateSourcePath("../sprite.png"));
}
