const std = @import("std");
const SaveStore = @import("unpolished-peas").core.SaveStore;

/// Private filesystem implementation used by the desktop host. It receives an
/// already resolved per-application data root from SDL, then owns only the
/// `saves/` child beneath it.
pub const NativeSaveStore = struct {
    allocator: std.mem.Allocator,
    directory: std.fs.Dir,
    store: SaveStore = undefined,

    const temporary_prefix = ".up-save-";
    const temporary_suffix = ".tmp";

    const operations = SaveStore.VTable{
        .read_size = readSize,
        .read = read,
        .write = write,
        .delete = delete,
        .exists = exists,
    };

    pub fn init(self: *NativeSaveStore, allocator: std.mem.Allocator, app_data_path: []const u8) !void {
        if (!std.fs.path.isAbsolute(app_data_path)) return error.InvalidSaveDataPath;
        const save_path = try std.fs.path.join(allocator, &.{ app_data_path, "saves" });
        defer allocator.free(save_path);
        std.fs.makeDirAbsolute(save_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        self.* = .{
            .allocator = allocator,
            .directory = try std.fs.openDirAbsolute(save_path, .{}),
        };
        self.store = SaveStore.init(self, &operations);
    }

    pub fn deinit(self: *NativeSaveStore) void {
        self.directory.close();
        self.* = undefined;
    }

    pub fn capability(self: *NativeSaveStore) *SaveStore {
        return &self.store;
    }

    fn readSize(context: *anyopaque, key: []const u8) SaveStore.Error!usize {
        const self: *NativeSaveStore = @ptrCast(@alignCast(context));
        const stat = self.directory.statFile(key) catch |err| return mapReadError(err);
        return std.math.cast(usize, stat.size) orelse error.TooLarge;
    }

    fn read(context: *anyopaque, key: []const u8, destination: []u8) SaveStore.Error!usize {
        const self: *NativeSaveStore = @ptrCast(@alignCast(context));
        const expected = readSize(context, key) catch |err| return err;
        if (expected > destination.len) return error.TooLarge;
        var file = self.directory.openFile(key, .{}) catch |err| return mapReadError(err);
        defer file.close();
        const count = file.readAll(destination[0..expected]) catch return error.Io;
        if (count != expected) return error.Io;
        return count;
    }

    fn write(context: *anyopaque, key: []const u8, bytes: []const u8) SaveStore.Error!void {
        const self: *NativeSaveStore = @ptrCast(@alignCast(context));
        var temporary_buffer: [temporary_prefix.len + SaveStore.max_key_bytes + temporary_suffix.len]u8 = undefined;
        const temporary = std.fmt.bufPrint(&temporary_buffer, "{s}{s}{s}", .{ temporary_prefix, key, temporary_suffix }) catch return error.Rejected;
        var file = self.directory.createFile(temporary, .{ .truncate = true }) catch |err| return mapWriteError(err);
        var renamed = false;
        defer {
            file.close();
            if (!renamed) self.directory.deleteFile(temporary) catch {};
        }
        file.writeAll(bytes) catch return error.Io;
        file.sync() catch return error.Io;
        self.directory.rename(temporary, key) catch |err| return mapWriteError(err);
        renamed = true;
    }

    fn delete(context: *anyopaque, key: []const u8) SaveStore.Error!void {
        const self: *NativeSaveStore = @ptrCast(@alignCast(context));
        self.directory.deleteFile(key) catch |err| return mapReadError(err);
    }

    fn exists(context: *anyopaque, key: []const u8) SaveStore.Error!bool {
        const self: *NativeSaveStore = @ptrCast(@alignCast(context));
        var file = self.directory.openFile(key, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            error.AccessDenied => return error.AccessDenied,
            else => return error.Io,
        };
        file.close();
        return true;
    }

    fn mapReadError(err: anyerror) SaveStore.Error {
        return switch (err) {
            error.FileNotFound => error.NotFound,
            error.AccessDenied => error.AccessDenied,
            error.FileTooBig => error.TooLarge,
            else => error.Io,
        };
    }

    fn mapWriteError(err: anyerror) SaveStore.Error {
        return switch (err) {
            error.AccessDenied => error.AccessDenied,
            else => error.Io,
        };
    }
};

test "native save store persists opaque bytes under one application root" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    var store: NativeSaveStore = undefined;
    try store.init(std.testing.allocator, root);
    defer store.deinit();

    const bytes = [_]u8{ 0, 1, 2, 250, 255 };
    try std.testing.expect(!(try store.capability().exists("progress")));
    try std.testing.expectError(error.NotFound, store.capability().readAlloc(std.testing.allocator, "progress", 64));
    try store.capability().write("progress", &bytes);
    try std.testing.expect(try store.capability().exists("progress"));
    const loaded = try store.capability().readAlloc(std.testing.allocator, "progress", 64);
    defer std.testing.allocator.free(loaded);
    try std.testing.expectEqualSlices(u8, &bytes, loaded);
    try store.capability().write("progress", "new");
    var fixed: [3]u8 = undefined;
    try std.testing.expectEqualStrings("new", try store.capability().read("progress", &fixed));
    try store.capability().write("empty", &.{});
    const empty = try store.capability().readAlloc(std.testing.allocator, "empty", 0);
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    try std.testing.expectError(error.TooLarge, store.capability().readAlloc(std.testing.allocator, "progress", 2));
    try store.capability().delete("progress");
    try std.testing.expect(!(try store.capability().exists("progress")));
}

test "native save store rejects path-like keys" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    var store: NativeSaveStore = undefined;
    try store.init(std.testing.allocator, root);
    defer store.deinit();
    for ([_][]const u8{ "..", "../outside", "a/b", "a\\b" }) |key| {
        try std.testing.expectError(error.InvalidKey, store.capability().write(key, "no"));
    }
}
