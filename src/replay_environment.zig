const std = @import("std");
const SaveStore = @import("save_data.zig").SaveStore;

/// Optional, owned initial conditions for a developer replay. Games choose
/// which saves matter and supply their own build/asset identity. Peas never
/// enumerates a user's store or serializes the game's memory.
pub const Environment = struct {
    pub const max_saves = 64;
    pub const max_save_bytes = 1024 * 1024;
    pub const max_identity_bytes = 256;
    pub const max_encoded_bytes = max_save_bytes + max_saves * (SaveStore.max_key_bytes + 9) + 3 * (max_identity_bytes + 4) + 4;

    pub const Identity = struct {
        game: []const u8,
        build: []const u8,
        assets: []const u8,

        pub fn check(self: Identity, expected: Identity) !void {
            if (!std.mem.eql(u8, self.game, expected.game)) return error.ReplayGameMismatch;
            if (!std.mem.eql(u8, self.build, expected.build)) return error.ReplayBuildMismatch;
            if (!std.mem.eql(u8, self.assets, expected.assets)) return error.ReplayAssetsMismatch;
        }
    };

    pub const SavedValue = struct {
        key: []const u8 = "",
        /// Missing and present-but-empty are distinct initial conditions.
        bytes: ?[]const u8 = null,
    };

    pub const CaptureOptions = struct {
        identity: Identity,
        save_data: ?*const SaveStore = null,
        save_keys: []const []const u8 = &.{},
    };

    identity: Identity,
    saves: []SavedValue,

    /// Capture before Game.init, while the game is not writing saves. Only
    /// explicitly named keys are read; at most 1 MiB of saved bytes is retained.
    pub fn capture(allocator: std.mem.Allocator, options: CaptureOptions) !Environment {
        try validateIdentity(options.identity);
        if (options.save_keys.len > max_saves) return error.ReplayEnvironmentTooLarge;
        if (options.save_keys.len != 0 and options.save_data == null) return error.SaveDataUnavailable;
        var self = try allocate(allocator, options.identity, options.save_keys.len);
        errdefer self.deinit(allocator);
        var remaining: usize = max_save_bytes;
        for (options.save_keys, self.saves, 0..) |key, *save, index| {
            try SaveStore.validateKey(key);
            for (options.save_keys[0..index]) |previous| if (std.mem.eql(u8, key, previous)) return error.DuplicateReplaySave;
            save.key = try allocator.dupe(u8, key);
            save.bytes = options.save_data.?.readAlloc(allocator, key, remaining) catch |err| switch (err) {
                error.NotFound => null,
                error.TooLarge => return error.ReplayEnvironmentTooLarge,
                else => return err,
            };
            if (save.bytes) |bytes| remaining -= bytes.len;
        }
        // Captures of the same store encode equally regardless of key order.
        std.mem.sort(SavedValue, self.saves, {}, lessThan);
        return self;
    }

    pub fn deinit(self: *Environment, allocator: std.mem.Allocator) void {
        for (self.saves) |save| {
            allocator.free(save.key);
            if (save.bytes) |bytes| allocator.free(bytes);
        }
        allocator.free(self.saves);
        allocator.free(self.identity.game);
        allocator.free(self.identity.build);
        allocator.free(self.identity.assets);
        self.* = undefined;
    }

    pub fn clone(self: Environment, allocator: std.mem.Allocator) !Environment {
        try self.validate();
        var result = try allocate(allocator, self.identity, self.saves.len);
        errdefer result.deinit(allocator);
        for (self.saves, result.saves) |save, *copy| {
            copy.key = try allocator.dupe(u8, save.key);
            if (save.bytes) |bytes| copy.bytes = try allocator.dupe(u8, bytes);
        }
        return result;
    }

    pub fn validate(self: Environment) !void {
        try validateIdentity(self.identity);
        if (self.saves.len > max_saves) return error.ReplayEnvironmentTooLarge;
        var remaining: usize = max_save_bytes;
        for (self.saves, 0..) |save, index| {
            try SaveStore.validateKey(save.key);
            for (self.saves[0..index]) |previous| if (std.mem.eql(u8, save.key, previous.key)) return error.DuplicateReplaySave;
            if (save.bytes) |bytes| {
                if (bytes.len > remaining) return error.ReplayEnvironmentTooLarge;
                remaining -= bytes.len;
            }
        }
    }

    pub fn encode(self: Environment, allocator: std.mem.Allocator) ![]u8 {
        try self.validate();
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        try appendBytes(&output, allocator, self.identity.game);
        try appendBytes(&output, allocator, self.identity.build);
        try appendBytes(&output, allocator, self.identity.assets);
        try appendU32(&output, allocator, @intCast(self.saves.len));
        for (self.saves) |save| {
            try appendBytes(&output, allocator, save.key);
            try output.append(allocator, @intFromBool(save.bytes != null));
            if (save.bytes) |bytes| try appendBytes(&output, allocator, bytes);
        }
        return output.toOwnedSlice(allocator);
    }

    pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Environment {
        if (bytes.len > max_encoded_bytes) return error.ReplayEnvironmentTooLarge;
        var reader = Reader{ .bytes = bytes };
        const identity = Identity{
            .game = try reader.blob(max_identity_bytes),
            .build = try reader.blob(max_identity_bytes),
            .assets = try reader.blob(max_identity_bytes),
        };
        try validateIdentity(identity);
        const count = try reader.number();
        if (count > max_saves) return error.ReplayEnvironmentTooLarge;
        var result = try allocate(allocator, identity, count);
        errdefer result.deinit(allocator);
        var remaining: usize = max_save_bytes;
        for (result.saves) |*save| {
            const key = try reader.blob(SaveStore.max_key_bytes);
            try SaveStore.validateKey(key);
            save.key = try allocator.dupe(u8, key);
            const present = (try reader.take(1))[0];
            if (present > 1) return error.InvalidReplayEnvironment;
            if (present == 1) {
                const value = try reader.blob(remaining);
                save.bytes = try allocator.dupe(u8, value);
                remaining -= value.len;
            }
        }
        if (reader.bytes.len != 0) return error.InvalidReplayEnvironment;
        try result.validate();
        return result;
    }

    fn allocate(allocator: std.mem.Allocator, identity: Identity, count: usize) !Environment {
        const game = try allocator.dupe(u8, identity.game);
        errdefer allocator.free(game);
        const build = try allocator.dupe(u8, identity.build);
        errdefer allocator.free(build);
        const assets = try allocator.dupe(u8, identity.assets);
        errdefer allocator.free(assets);
        const saves = try allocator.alloc(SavedValue, count);
        @memset(saves, .{});
        return .{ .identity = .{ .game = game, .build = build, .assets = assets }, .saves = saves };
    }

    fn validateIdentity(identity: Identity) !void {
        for ([_][]const u8{ identity.game, identity.build, identity.assets }) |value| {
            if (value.len == 0 or value.len > max_identity_bytes) return error.InvalidReplayIdentity;
        }
    }

    fn lessThan(_: void, a: SavedValue, b: SavedValue) bool {
        return std.mem.lessThan(u8, a.key, b.key);
    }
};

fn appendU32(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try output.appendSlice(allocator, &bytes);
}

fn appendBytes(output: *std.ArrayList(u8), allocator: std.mem.Allocator, bytes: []const u8) !void {
    try appendU32(output, allocator, @intCast(bytes.len));
    try output.appendSlice(allocator, bytes);
}

const Reader = struct {
    bytes: []const u8,

    fn take(self: *Reader, count: usize) ![]const u8 {
        if (count > self.bytes.len) return error.InvalidReplayEnvironment;
        const result = self.bytes[0..count];
        self.bytes = self.bytes[count..];
        return result;
    }

    fn number(self: *Reader) !u32 {
        return std.mem.readInt(u32, (try self.take(4))[0..4], .little);
    }

    fn blob(self: *Reader, max_bytes: usize) ![]const u8 {
        const count = try self.number();
        if (count > max_bytes) return error.ReplayEnvironmentTooLarge;
        return self.take(count);
    }
};
