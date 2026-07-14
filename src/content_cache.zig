const std = @import("std");

pub const magic = "UPCC";
pub const version: u16 = 1;
pub const max_payload_bytes: usize = 64 * 1024 * 1024;
const header_size = magic.len + @sizeOf(u16) + @sizeOf(u8) + @sizeOf(u8) + @sizeOf(u64) + @sizeOf(u32);

pub const Kind = enum(u8) { scene = 1, catalog = 2, map = 3 };

pub const Cache = struct {
    allocator: std.mem.Allocator,
    kind: Kind,
    fingerprint: u64,
    payload: []u8,

    pub fn deinit(self: *Cache) void {
        self.allocator.free(self.payload);
        self.* = undefined;
    }
};

pub fn encode(allocator: std.mem.Allocator, kind: Kind, fingerprint: u64, payload: []const u8) ![]u8 {
    if (payload.len > max_payload_bytes) return error.CacheTooLarge;
    const output = try allocator.alloc(u8, header_size + payload.len);
    errdefer allocator.free(output);
    @memcpy(output[0..magic.len], magic);
    std.mem.writeInt(u16, output[4..6], version, .little);
    output[6] = @intFromEnum(kind);
    output[7] = 0;
    std.mem.writeInt(u64, output[8..16], fingerprint, .little);
    std.mem.writeInt(u32, output[16..20], @intCast(payload.len), .little);
    @memcpy(output[header_size..], payload);
    return output;
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Cache {
    if (bytes.len < header_size or !std.mem.eql(u8, bytes[0..magic.len], magic)) return error.InvalidCacheMagic;
    if (std.mem.readInt(u16, bytes[4..6], .little) != version) return error.UnsupportedCacheVersion;
    const kind = std.meta.intToEnum(Kind, bytes[6]) catch return error.InvalidCacheKind;
    if (bytes[7] != 0) return error.InvalidCacheHeader;
    const payload_len: usize = std.mem.readInt(u32, bytes[16..20], .little);
    if (payload_len > max_payload_bytes or bytes.len != header_size + payload_len) return error.InvalidCacheSize;
    return .{ .allocator = allocator, .kind = kind, .fingerprint = std.mem.readInt(u64, bytes[8..16], .little), .payload = try allocator.dupe(u8, bytes[header_size..]) };
}

test "content cache validates magic version kind and size" {
    const encoded = try encode(std.testing.allocator, .scene, 42, "scene");
    defer std.testing.allocator.free(encoded);
    var cache = try decode(std.testing.allocator, encoded);
    defer cache.deinit();
    try std.testing.expectEqual(Kind.scene, cache.kind);
    try std.testing.expectEqual(@as(u64, 42), cache.fingerprint);
    try std.testing.expectEqualStrings("scene", cache.payload);
    try std.testing.expectError(error.InvalidCacheMagic, decode(std.testing.allocator, "bad"));
    var unsupported = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(unsupported);
    unsupported[4] = 2;
    try std.testing.expectError(error.UnsupportedCacheVersion, decode(std.testing.allocator, unsupported));
}
