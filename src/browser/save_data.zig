const builtin = @import("builtin");
const up = @import("unpolished-peas");
const contract = @import("contract.zig");

/// Browser-runtime-private adapter from the host's synchronous localStorage
/// ABI to the ordinary `up.core.SaveStore` capability.
pub fn Store(comptime application_id: []const u8) type {
    comptime if (!up.core.SaveStore.isValidApplicationId(application_id)) @compileError("browser Game.storage_id must be a portable application identifier");

    return struct {
        const Self = @This();
        const SaveStore = up.core.SaveStore;
        const composite_key_max_bytes = application_id.len + 1 + SaveStore.max_key_bytes;

        store: SaveStore = undefined,

        const operations = SaveStore.VTable{
            .read_size = readSize,
            .read = read,
            .write = write,
            .delete = delete,
            .exists = exists,
        };

        pub fn init(self: *Self) void {
            self.store = SaveStore.init(self, &operations);
        }

        pub fn capability(self: *Self) *SaveStore {
            return &self.store;
        }

        fn readSize(context: *anyopaque, key: []const u8) SaveStore.Error!usize {
            _ = context;
            var key_buffer: [composite_key_max_bytes]u8 = undefined;
            const composite_key = compositeKey(key, &key_buffer) catch return error.Rejected;
            const result = contract.readStorage(pointer(composite_key), @intCast(composite_key.len), 0, 0);
            return mapReadResult(result);
        }

        fn read(context: *anyopaque, key: []const u8, destination: []u8) SaveStore.Error!usize {
            _ = context;
            var key_buffer: [composite_key_max_bytes]u8 = undefined;
            const composite_key = compositeKey(key, &key_buffer) catch return error.Rejected;
            const result = contract.readStorage(pointer(composite_key), @intCast(composite_key.len), pointer(destination), @intCast(destination.len));
            return mapReadResult(result);
        }

        fn write(context: *anyopaque, key: []const u8, bytes: []const u8) SaveStore.Error!void {
            _ = context;
            var key_buffer: [composite_key_max_bytes]u8 = undefined;
            const composite_key = compositeKey(key, &key_buffer) catch return error.Rejected;
            const result = contract.writeStorage(pointer(composite_key), @intCast(composite_key.len), pointer(bytes), @intCast(bytes.len));
            try mapStatus(result);
        }

        fn delete(context: *anyopaque, key: []const u8) SaveStore.Error!void {
            _ = context;
            var key_buffer: [composite_key_max_bytes]u8 = undefined;
            const composite_key = compositeKey(key, &key_buffer) catch return error.Rejected;
            const result = contract.removeStorage(pointer(composite_key), @intCast(composite_key.len));
            try mapStatus(result);
        }

        fn exists(context: *anyopaque, key: []const u8) SaveStore.Error!bool {
            _ = context;
            readSize(context, key) catch |err| switch (err) {
                error.NotFound => return false,
                else => return err,
            };
            return true;
        }

        fn compositeKey(key: []const u8, buffer: *[composite_key_max_bytes]u8) ![]const u8 {
            if (key.len > SaveStore.max_key_bytes) return error.InvalidKey;
            @memcpy(buffer[0..application_id.len], application_id);
            buffer[application_id.len] = ':';
            @memcpy(buffer[application_id.len + 1 .. application_id.len + 1 + key.len], key);
            return buffer[0 .. application_id.len + 1 + key.len];
        }

        fn mapReadResult(value: i32) SaveStore.Error!usize {
            if (value >= 0) return @intCast(value);
            return mapStatus(value);
        }

        fn mapStatus(value: i32) SaveStore.Error!void {
            return switch (value) {
                @intFromEnum(contract.Status.ok) => {},
                @intFromEnum(contract.Status.not_found) => error.NotFound,
                @intFromEnum(contract.Status.invalid_argument) => error.Rejected,
                @intFromEnum(contract.Status.unavailable) => error.Unavailable,
                @intFromEnum(contract.Status.rejected) => error.Rejected,
                @intFromEnum(contract.Status.corrupt) => error.Corrupt,
                else => error.Rejected,
            };
        }

        fn pointer(bytes: []const u8) u32 {
            if (builtin.target.cpu.arch != .wasm32) return 0;
            return @intCast(@intFromPtr(bytes.ptr));
        }
    };
}
