const std = @import("std");
const SaveStore = @import("unpolished-peas").core.SaveStore;

/// Private filesystem implementation used by the desktop host. It receives an
/// already resolved per-application data root from SDL, then owns only the
/// `saves/` child beneath it.
pub const NativeSaveStore = struct {
    allocator: std.mem.Allocator,
    directory: std.fs.Dir,
    store: SaveStore = undefined,

    // Two dots are forbidden in game keys. Staging files can therefore never
    // alias a valid save, even when two game instances save concurrently.
    const temporary_prefix = ".up-save..";
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
        var file = self.directory.openFile(key, .{}) catch |err| return mapReadError(err);
        defer file.close();
        const stat = file.stat() catch |err| return mapReadError(err);
        if (stat.kind != .file) return error.Corrupt;
        return std.math.cast(usize, stat.size) orelse error.TooLarge;
    }

    fn read(context: *anyopaque, key: []const u8, destination: []u8) SaveStore.Error!usize {
        const self: *NativeSaveStore = @ptrCast(@alignCast(context));
        var file = self.directory.openFile(key, .{}) catch |err| return mapReadError(err);
        defer file.close();
        // Stat the opened file, so a replacement rename cannot make us read
        // a prefix sized from a different generation of the save.
        const stat = file.stat() catch |err| return mapReadError(err);
        if (stat.kind != .file) return error.Corrupt;
        const expected = std.math.cast(usize, stat.size) orelse return error.TooLarge;
        if (expected > destination.len) return error.TooLarge;
        const count = file.readAll(destination[0..expected]) catch return error.Io;
        if (count != expected) return error.Io;
        var extra: [1]u8 = undefined;
        if ((file.read(&extra) catch return error.Io) != 0) return error.TooLarge;
        return count;
    }

    fn write(context: *anyopaque, key: []const u8, bytes: []const u8) SaveStore.Error!void {
        const self: *NativeSaveStore = @ptrCast(@alignCast(context));
        var temporary_buffer: [temporary_prefix.len + 32 + temporary_suffix.len]u8 = undefined;
        var temporary: []const u8 = undefined;
        var file = for (0..32) |_| {
            const nonce = std.fmt.hex(std.crypto.random.int(u128));
            temporary = std.fmt.bufPrint(&temporary_buffer, "{s}{s}{s}", .{ temporary_prefix, nonce, temporary_suffix }) catch unreachable;
            break self.directory.createFile(temporary, .{ .exclusive = true }) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => return mapWriteError(err),
            };
        } else return error.Io;
        var file_open = true;
        var renamed = false;
        defer {
            if (file_open) file.close();
            if (!renamed) self.directory.deleteFile(temporary) catch {};
        }
        file.writeAll(bytes) catch return error.Io;
        file.sync() catch return error.Io;
        file.close();
        file_open = false;
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

test "save keys cannot collide with staging files" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    var store: NativeSaveStore = undefined;
    try store.init(std.testing.allocator, root);
    defer store.deinit();

    // This is a valid user key that the previous staging scheme overwrote.
    try store.capability().write(".up-save-progress.tmp", "another slot");
    try store.capability().write("progress", "checkpoint");
    var bytes: [32]u8 = undefined;
    try std.testing.expectEqualStrings("another slot", try store.capability().read(".up-save-progress.tmp", &bytes));
    try std.testing.expectEqualStrings("checkpoint", try store.capability().read("progress", &bytes));
}

test "failed publication removes only its staging file and permits retry" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    var store: NativeSaveStore = undefined;
    try store.init(std.testing.allocator, root);
    defer store.deinit();
    try store.capability().write("settings", "keep");
    try store.directory.makeDir("progress");
    try store.directory.writeFile(.{ .sub_path = "progress/keep", .data = "untouched" });
    if (store.capability().write("progress", "new")) |_| return error.ExpectedPublicationFailure else |err| switch (err) {
        error.Io, error.AccessDenied => {},
        else => return err,
    }
    var bytes: [32]u8 = undefined;
    try std.testing.expectEqualStrings("keep", try store.capability().read("settings", &bytes));
    if (store.capability().read("progress", &bytes)) |_| return error.ExpectedNonFileFailure else |err| switch (err) {
        error.Corrupt, error.Io, error.AccessDenied => {},
        else => return err,
    }
    var directory = try store.directory.openDir(".", .{ .iterate = true });
    defer directory.close();
    var entries = directory.iterate();
    while (try entries.next()) |entry| try std.testing.expect(!std.mem.startsWith(u8, entry.name, NativeSaveStore.temporary_prefix));
    try store.directory.deleteFile("progress/keep");
    try store.directory.deleteDir("progress");
    try store.capability().write("progress", "retry");
    try std.testing.expectEqualStrings("retry", try store.capability().read("progress", &bytes));
}

test "concurrent game instances publish complete saves" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const Writer = struct {
        root: []const u8,
        byte: u8,
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            self.save() catch |err| {
                self.failure = err;
            };
        }

        fn save(self: *@This()) !void {
            var store: NativeSaveStore = undefined;
            try store.init(std.heap.page_allocator, self.root);
            defer store.deinit();
            var bytes: [1024]u8 = undefined;
            @memset(&bytes, self.byte);
            for (0..12) |_| store.capability().write("progress", &bytes) catch |err| {
                // Windows may reject a simultaneous replacement while another
                // rename holds the destination. Failed writes still leave a
                // complete value, and subsequent writes can retry.
                if (@import("builtin").os.tag == .windows and err == error.AccessDenied) continue;
                return err;
            };
        }
    };
    var writers = [_]Writer{ .{ .root = root, .byte = 17 }, .{ .root = root, .byte = 83 } };
    var threads: [writers.len]std.Thread = undefined;
    var started: usize = 0;
    {
        defer for (threads[0..started]) |thread| thread.join();
        for (&writers, &threads) |*writer, *thread| {
            thread.* = try std.Thread.spawn(.{}, Writer.run, .{writer});
            started += 1;
        }
    }
    for (writers) |writer| if (writer.failure) |err| return err;
    var store: NativeSaveStore = undefined;
    try store.init(std.testing.allocator, root);
    defer store.deinit();
    const bytes = try store.capability().readAlloc(std.testing.allocator, "progress", 1024);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 1024), bytes.len);
    try std.testing.expect(bytes[0] == 17 or bytes[0] == 83);
    for (bytes) |byte| try std.testing.expectEqual(bytes[0], byte);
}
