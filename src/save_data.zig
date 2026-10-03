const std = @import("std");

/// Backend-neutral persistence for small, game-owned byte blobs.
///
/// A store is supplied by the host through `GameContext.save_data`. Keys are
/// portable identifiers, not paths: they are limited to ASCII letters,
/// numbers, `.`, `_`, and `-`. The game owns the bytes' format and any
/// versioning or migration policy.
pub const SaveStore = struct {
    pub const max_key_bytes: usize = 64;
    pub const max_application_id_bytes: usize = 128;

    pub const Error = error{
        InvalidKey,
        NotFound,
        TooLarge,
        Unavailable,
        Rejected,
        Corrupt,
        AccessDenied,
        Io,
        OutOfMemory,
    };

    pub const VTable = struct {
        read_size: *const fn (context: *anyopaque, key: []const u8) Error!usize,
        read: *const fn (context: *anyopaque, key: []const u8, destination: []u8) Error!usize,
        write: *const fn (context: *anyopaque, key: []const u8, bytes: []const u8) Error!void,
        delete: *const fn (context: *anyopaque, key: []const u8) Error!void,
        exists: *const fn (context: *anyopaque, key: []const u8) Error!bool,
    };

    context: *anyopaque,
    vtable: *const VTable,

    /// Hosts construct this once for a private backend implementation. Games
    /// receive the resulting capability from `GameContext`; they should not
    /// need to create stores themselves.
    pub fn init(context: *anyopaque, vtable: *const VTable) SaveStore {
        return .{ .context = context, .vtable = vtable };
    }

    /// Reads a blob into caller-owned storage. `TooLarge` means the supplied
    /// destination cannot hold the stored blob.
    pub fn read(self: *const SaveStore, key: []const u8, destination: []u8) Error![]const u8 {
        try validateKey(key);
        const count = try self.vtable.read(self.context, key, destination);
        if (count > destination.len) return error.Rejected;
        return destination[0..count];
    }

    /// Allocates and returns the full stored blob. The caller owns the result
    /// and must free it with the same allocator. `max_bytes` bounds both the
    /// allocation and the accepted stored size.
    pub fn readAlloc(self: *const SaveStore, allocator: std.mem.Allocator, key: []const u8, max_bytes: usize) Error![]u8 {
        try validateKey(key);
        const byte_len = try self.vtable.read_size(self.context, key);
        if (byte_len > max_bytes) return error.TooLarge;
        const bytes = allocator.alloc(u8, byte_len) catch return error.OutOfMemory;
        errdefer allocator.free(bytes);
        const read_len = try self.vtable.read(self.context, key, bytes);
        if (read_len != byte_len) return error.Rejected;
        return bytes;
    }

    pub fn write(self: *const SaveStore, key: []const u8, bytes: []const u8) Error!void {
        try validateKey(key);
        return self.vtable.write(self.context, key, bytes);
    }

    pub fn delete(self: *const SaveStore, key: []const u8) Error!void {
        try validateKey(key);
        return self.vtable.delete(self.context, key);
    }

    pub fn exists(self: *const SaveStore, key: []const u8) Error!bool {
        try validateKey(key);
        return self.vtable.exists(self.context, key);
    }

    pub fn validateKey(key: []const u8) Error!void {
        // `.` is useful for game-controlled versions (for example,
        // `settings.v2`), but two consecutive dots have no portable
        // key/value meaning and resemble parent-directory traversal on a
        // filesystem. Reject them rather than normalizing a game key.
        if (!isValidIdentifier(key, max_key_bytes) or std.mem.indexOf(u8, key, "..") != null) return error.InvalidKey;
    }

    /// Browser callback games declare `pub const storage_id = "...";` so the
    /// browser host can keep their localStorage keys separate. Desktop games
    /// use `sdl.Config.organization` plus `sdl.Config.application` instead.
    pub fn isValidApplicationId(application_id: []const u8) bool {
        return isValidIdentifier(application_id, max_application_id_bytes);
    }
};

fn isValidIdentifier(value: []const u8, max_bytes: usize) bool {
    if (value.len == 0 or value.len > max_bytes) return false;
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '_' or byte == '-') continue;
        return false;
    }
    return true;
}

test "save keys are small portable identifiers" {
    try SaveStore.validateKey("settings");
    try SaveStore.validateKey("slot-1");
    try SaveStore.validateKey("progress.v2");
    try std.testing.expect(SaveStore.isValidApplicationId("example-game"));
    for ([_][]const u8{ "", "..", "progress..v2", "../save", "a/b", "a\\b", "a:b", "a\x00b" }) |key| {
        try std.testing.expectError(error.InvalidKey, SaveStore.validateKey(key));
    }
}
