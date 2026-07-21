const std = @import("std");

pub const max_hpack_dynamic_table_bytes: usize = 4096;
pub const max_hpack_header_list_bytes: usize = 64 * 1024;
pub const max_hpack_headers: usize = 128;
pub const HpackError = std.mem.Allocator.Error || error{ InvalidConfiguration, Incomplete, IntegerOverflow, InvalidIndex, InvalidHuffman, HeaderListTooLarge, HeaderCountExceeded, DynamicTableSizeExceeded, DynamicTableSizeUpdateAfterHeader };
pub const HpackHeader = struct { name: []const u8, value: []const u8 };

pub const HpackDecoderConfig = struct {
    maximum_dynamic_table_bytes: usize = max_hpack_dynamic_table_bytes,
    maximum_header_list_bytes: usize = max_hpack_header_list_bytes,
    maximum_headers: usize = max_hpack_headers,

    pub fn validate(self: HpackDecoderConfig) HpackError!void {
        if (self.maximum_header_list_bytes == 0 or self.maximum_headers == 0) return error.InvalidConfiguration;
    }
};

pub const HpackHeaderList = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(HpackHeader) = .empty,
    bytes: usize = 0,

    pub fn deinit(self: *HpackHeaderList) void {
        for (self.entries.items) |header| {
            self.allocator.free(header.name);
            self.allocator.free(header.value);
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    fn append(self: *HpackHeaderList, config: HpackDecoderConfig, name: []const u8, value: []const u8) HpackError!void {
        if (self.entries.items.len == config.maximum_headers) return error.HeaderCountExceeded;
        if (name.len > config.maximum_header_list_bytes -| self.bytes or value.len > config.maximum_header_list_bytes - self.bytes - name.len) return error.HeaderListTooLarge;
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);
        try self.entries.append(self.allocator, .{ .name = owned_name, .value = owned_value });
        self.bytes += name.len + value.len;
    }
};

const DynamicEntry = struct {
    name: []u8,
    value: []u8,
    bytes: usize,

    fn deinit(self: *DynamicEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value);
        self.* = undefined;
    }
};

const HuffmanCode = struct { bits: u32, length: u8 };

const static_table = [_]HpackHeader{
    .{ .name = ":authority", .value = "" },
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":method", .value = "POST" },
    .{ .name = ":path", .value = "/" },
    .{ .name = ":path", .value = "/index.html" },
    .{ .name = ":scheme", .value = "http" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":status", .value = "200" },
    .{ .name = ":status", .value = "204" },
    .{ .name = ":status", .value = "206" },
    .{ .name = ":status", .value = "304" },
    .{ .name = ":status", .value = "400" },
    .{ .name = ":status", .value = "404" },
    .{ .name = ":status", .value = "500" },
    .{ .name = "accept-charset", .value = "" },
    .{ .name = "accept-encoding", .value = "gzip, deflate" },
    .{ .name = "accept-language", .value = "" },
    .{ .name = "accept-ranges", .value = "" },
    .{ .name = "accept", .value = "" },
    .{ .name = "access-control-allow-origin", .value = "" },
    .{ .name = "age", .value = "" },
    .{ .name = "allow", .value = "" },
    .{ .name = "authorization", .value = "" },
    .{ .name = "cache-control", .value = "" },
    .{ .name = "content-disposition", .value = "" },
    .{ .name = "content-encoding", .value = "" },
    .{ .name = "content-language", .value = "" },
    .{ .name = "content-length", .value = "" },
    .{ .name = "content-location", .value = "" },
    .{ .name = "content-range", .value = "" },
    .{ .name = "content-type", .value = "" },
    .{ .name = "cookie", .value = "" },
    .{ .name = "date", .value = "" },
    .{ .name = "etag", .value = "" },
    .{ .name = "expect", .value = "" },
    .{ .name = "expires", .value = "" },
    .{ .name = "from", .value = "" },
    .{ .name = "host", .value = "" },
    .{ .name = "if-match", .value = "" },
    .{ .name = "if-modified-since", .value = "" },
    .{ .name = "if-none-match", .value = "" },
    .{ .name = "if-range", .value = "" },
    .{ .name = "if-unmodified-since", .value = "" },
    .{ .name = "last-modified", .value = "" },
    .{ .name = "link", .value = "" },
    .{ .name = "location", .value = "" },
    .{ .name = "max-forwards", .value = "" },
    .{ .name = "proxy-authenticate", .value = "" },
    .{ .name = "proxy-authorization", .value = "" },
    .{ .name = "range", .value = "" },
    .{ .name = "referer", .value = "" },
    .{ .name = "refresh", .value = "" },
    .{ .name = "retry-after", .value = "" },
    .{ .name = "server", .value = "" },
    .{ .name = "set-cookie", .value = "" },
    .{ .name = "strict-transport-security", .value = "" },
    .{ .name = "transfer-encoding", .value = "" },
    .{ .name = "user-agent", .value = "" },
    .{ .name = "vary", .value = "" },
    .{ .name = "via", .value = "" },
    .{ .name = "www-authenticate", .value = "" },
};

const huffman_codes = [_]HuffmanCode{
    .{ .bits = 0x1ff8, .length = 13 },
    .{ .bits = 0x7fffd8, .length = 23 },
    .{ .bits = 0xfffffe2, .length = 28 },
    .{ .bits = 0xfffffe3, .length = 28 },
    .{ .bits = 0xfffffe4, .length = 28 },
    .{ .bits = 0xfffffe5, .length = 28 },
    .{ .bits = 0xfffffe6, .length = 28 },
    .{ .bits = 0xfffffe7, .length = 28 },
    .{ .bits = 0xfffffe8, .length = 28 },
    .{ .bits = 0xffffea, .length = 24 },
    .{ .bits = 0x3ffffffc, .length = 30 },
    .{ .bits = 0xfffffe9, .length = 28 },
    .{ .bits = 0xfffffea, .length = 28 },
    .{ .bits = 0x3ffffffd, .length = 30 },
    .{ .bits = 0xfffffeb, .length = 28 },
    .{ .bits = 0xfffffec, .length = 28 },
    .{ .bits = 0xfffffed, .length = 28 },
    .{ .bits = 0xfffffee, .length = 28 },
    .{ .bits = 0xfffffef, .length = 28 },
    .{ .bits = 0xffffff0, .length = 28 },
    .{ .bits = 0xffffff1, .length = 28 },
    .{ .bits = 0xffffff2, .length = 28 },
    .{ .bits = 0x3ffffffe, .length = 30 },
    .{ .bits = 0xffffff3, .length = 28 },
    .{ .bits = 0xffffff4, .length = 28 },
    .{ .bits = 0xffffff5, .length = 28 },
    .{ .bits = 0xffffff6, .length = 28 },
    .{ .bits = 0xffffff7, .length = 28 },
    .{ .bits = 0xffffff8, .length = 28 },
    .{ .bits = 0xffffff9, .length = 28 },
    .{ .bits = 0xffffffa, .length = 28 },
    .{ .bits = 0xffffffb, .length = 28 },
    .{ .bits = 0x14, .length = 6 },
    .{ .bits = 0x3f8, .length = 10 },
    .{ .bits = 0x3f9, .length = 10 },
    .{ .bits = 0xffa, .length = 12 },
    .{ .bits = 0x1ff9, .length = 13 },
    .{ .bits = 0x15, .length = 6 },
    .{ .bits = 0xf8, .length = 8 },
    .{ .bits = 0x7fa, .length = 11 },
    .{ .bits = 0x3fa, .length = 10 },
    .{ .bits = 0x3fb, .length = 10 },
    .{ .bits = 0xf9, .length = 8 },
    .{ .bits = 0x7fb, .length = 11 },
    .{ .bits = 0xfa, .length = 8 },
    .{ .bits = 0x16, .length = 6 },
    .{ .bits = 0x17, .length = 6 },
    .{ .bits = 0x18, .length = 6 },
    .{ .bits = 0x0, .length = 5 },
    .{ .bits = 0x1, .length = 5 },
    .{ .bits = 0x2, .length = 5 },
    .{ .bits = 0x19, .length = 6 },
    .{ .bits = 0x1a, .length = 6 },
    .{ .bits = 0x1b, .length = 6 },
    .{ .bits = 0x1c, .length = 6 },
    .{ .bits = 0x1d, .length = 6 },
    .{ .bits = 0x1e, .length = 6 },
    .{ .bits = 0x1f, .length = 6 },
    .{ .bits = 0x5c, .length = 7 },
    .{ .bits = 0xfb, .length = 8 },
    .{ .bits = 0x7ffc, .length = 15 },
    .{ .bits = 0x20, .length = 6 },
    .{ .bits = 0xffb, .length = 12 },
    .{ .bits = 0x3fc, .length = 10 },
    .{ .bits = 0x1ffa, .length = 13 },
    .{ .bits = 0x21, .length = 6 },
    .{ .bits = 0x5d, .length = 7 },
    .{ .bits = 0x5e, .length = 7 },
    .{ .bits = 0x5f, .length = 7 },
    .{ .bits = 0x60, .length = 7 },
    .{ .bits = 0x61, .length = 7 },
    .{ .bits = 0x62, .length = 7 },
    .{ .bits = 0x63, .length = 7 },
    .{ .bits = 0x64, .length = 7 },
    .{ .bits = 0x65, .length = 7 },
    .{ .bits = 0x66, .length = 7 },
    .{ .bits = 0x67, .length = 7 },
    .{ .bits = 0x68, .length = 7 },
    .{ .bits = 0x69, .length = 7 },
    .{ .bits = 0x6a, .length = 7 },
    .{ .bits = 0x6b, .length = 7 },
    .{ .bits = 0x6c, .length = 7 },
    .{ .bits = 0x6d, .length = 7 },
    .{ .bits = 0x6e, .length = 7 },
    .{ .bits = 0x6f, .length = 7 },
    .{ .bits = 0x70, .length = 7 },
    .{ .bits = 0x71, .length = 7 },
    .{ .bits = 0x72, .length = 7 },
    .{ .bits = 0xfc, .length = 8 },
    .{ .bits = 0x73, .length = 7 },
    .{ .bits = 0xfd, .length = 8 },
    .{ .bits = 0x1ffb, .length = 13 },
    .{ .bits = 0x7fff0, .length = 19 },
    .{ .bits = 0x1ffc, .length = 13 },
    .{ .bits = 0x3ffc, .length = 14 },
    .{ .bits = 0x22, .length = 6 },
    .{ .bits = 0x7ffd, .length = 15 },
    .{ .bits = 0x3, .length = 5 },
    .{ .bits = 0x23, .length = 6 },
    .{ .bits = 0x4, .length = 5 },
    .{ .bits = 0x24, .length = 6 },
    .{ .bits = 0x5, .length = 5 },
    .{ .bits = 0x25, .length = 6 },
    .{ .bits = 0x26, .length = 6 },
    .{ .bits = 0x27, .length = 6 },
    .{ .bits = 0x6, .length = 5 },
    .{ .bits = 0x74, .length = 7 },
    .{ .bits = 0x75, .length = 7 },
    .{ .bits = 0x28, .length = 6 },
    .{ .bits = 0x29, .length = 6 },
    .{ .bits = 0x2a, .length = 6 },
    .{ .bits = 0x7, .length = 5 },
    .{ .bits = 0x2b, .length = 6 },
    .{ .bits = 0x76, .length = 7 },
    .{ .bits = 0x2c, .length = 6 },
    .{ .bits = 0x8, .length = 5 },
    .{ .bits = 0x9, .length = 5 },
    .{ .bits = 0x2d, .length = 6 },
    .{ .bits = 0x77, .length = 7 },
    .{ .bits = 0x78, .length = 7 },
    .{ .bits = 0x79, .length = 7 },
    .{ .bits = 0x7a, .length = 7 },
    .{ .bits = 0x7b, .length = 7 },
    .{ .bits = 0x7ffe, .length = 15 },
    .{ .bits = 0x7fc, .length = 11 },
    .{ .bits = 0x3ffd, .length = 14 },
    .{ .bits = 0x1ffd, .length = 13 },
    .{ .bits = 0xffffffc, .length = 28 },
    .{ .bits = 0xfffe6, .length = 20 },
    .{ .bits = 0x3fffd2, .length = 22 },
    .{ .bits = 0xfffe7, .length = 20 },
    .{ .bits = 0xfffe8, .length = 20 },
    .{ .bits = 0x3fffd3, .length = 22 },
    .{ .bits = 0x3fffd4, .length = 22 },
    .{ .bits = 0x3fffd5, .length = 22 },
    .{ .bits = 0x7fffd9, .length = 23 },
    .{ .bits = 0x3fffd6, .length = 22 },
    .{ .bits = 0x7fffda, .length = 23 },
    .{ .bits = 0x7fffdb, .length = 23 },
    .{ .bits = 0x7fffdc, .length = 23 },
    .{ .bits = 0x7fffdd, .length = 23 },
    .{ .bits = 0x7fffde, .length = 23 },
    .{ .bits = 0xffffeb, .length = 24 },
    .{ .bits = 0x7fffdf, .length = 23 },
    .{ .bits = 0xffffec, .length = 24 },
    .{ .bits = 0xffffed, .length = 24 },
    .{ .bits = 0x3fffd7, .length = 22 },
    .{ .bits = 0x7fffe0, .length = 23 },
    .{ .bits = 0xffffee, .length = 24 },
    .{ .bits = 0x7fffe1, .length = 23 },
    .{ .bits = 0x7fffe2, .length = 23 },
    .{ .bits = 0x7fffe3, .length = 23 },
    .{ .bits = 0x7fffe4, .length = 23 },
    .{ .bits = 0x1fffdc, .length = 21 },
    .{ .bits = 0x3fffd8, .length = 22 },
    .{ .bits = 0x7fffe5, .length = 23 },
    .{ .bits = 0x3fffd9, .length = 22 },
    .{ .bits = 0x7fffe6, .length = 23 },
    .{ .bits = 0x7fffe7, .length = 23 },
    .{ .bits = 0xffffef, .length = 24 },
    .{ .bits = 0x3fffda, .length = 22 },
    .{ .bits = 0x1fffdd, .length = 21 },
    .{ .bits = 0xfffe9, .length = 20 },
    .{ .bits = 0x3fffdb, .length = 22 },
    .{ .bits = 0x3fffdc, .length = 22 },
    .{ .bits = 0x7fffe8, .length = 23 },
    .{ .bits = 0x7fffe9, .length = 23 },
    .{ .bits = 0x1fffde, .length = 21 },
    .{ .bits = 0x7fffea, .length = 23 },
    .{ .bits = 0x3fffdd, .length = 22 },
    .{ .bits = 0x3fffde, .length = 22 },
    .{ .bits = 0xfffff0, .length = 24 },
    .{ .bits = 0x1fffdf, .length = 21 },
    .{ .bits = 0x3fffdf, .length = 22 },
    .{ .bits = 0x7fffeb, .length = 23 },
    .{ .bits = 0x7fffec, .length = 23 },
    .{ .bits = 0x1fffe0, .length = 21 },
    .{ .bits = 0x1fffe1, .length = 21 },
    .{ .bits = 0x3fffe0, .length = 22 },
    .{ .bits = 0x1fffe2, .length = 21 },
    .{ .bits = 0x7fffed, .length = 23 },
    .{ .bits = 0x3fffe1, .length = 22 },
    .{ .bits = 0x7fffee, .length = 23 },
    .{ .bits = 0x7fffef, .length = 23 },
    .{ .bits = 0xfffea, .length = 20 },
    .{ .bits = 0x3fffe2, .length = 22 },
    .{ .bits = 0x3fffe3, .length = 22 },
    .{ .bits = 0x3fffe4, .length = 22 },
    .{ .bits = 0x7ffff0, .length = 23 },
    .{ .bits = 0x3fffe5, .length = 22 },
    .{ .bits = 0x3fffe6, .length = 22 },
    .{ .bits = 0x7ffff1, .length = 23 },
    .{ .bits = 0x3ffffe0, .length = 26 },
    .{ .bits = 0x3ffffe1, .length = 26 },
    .{ .bits = 0xfffeb, .length = 20 },
    .{ .bits = 0x7fff1, .length = 19 },
    .{ .bits = 0x3fffe7, .length = 22 },
    .{ .bits = 0x7ffff2, .length = 23 },
    .{ .bits = 0x3fffe8, .length = 22 },
    .{ .bits = 0x1ffffec, .length = 25 },
    .{ .bits = 0x3ffffe2, .length = 26 },
    .{ .bits = 0x3ffffe3, .length = 26 },
    .{ .bits = 0x3ffffe4, .length = 26 },
    .{ .bits = 0x7ffffde, .length = 27 },
    .{ .bits = 0x7ffffdf, .length = 27 },
    .{ .bits = 0x3ffffe5, .length = 26 },
    .{ .bits = 0xfffff1, .length = 24 },
    .{ .bits = 0x1ffffed, .length = 25 },
    .{ .bits = 0x7fff2, .length = 19 },
    .{ .bits = 0x1fffe3, .length = 21 },
    .{ .bits = 0x3ffffe6, .length = 26 },
    .{ .bits = 0x7ffffe0, .length = 27 },
    .{ .bits = 0x7ffffe1, .length = 27 },
    .{ .bits = 0x3ffffe7, .length = 26 },
    .{ .bits = 0x7ffffe2, .length = 27 },
    .{ .bits = 0xfffff2, .length = 24 },
    .{ .bits = 0x1fffe4, .length = 21 },
    .{ .bits = 0x1fffe5, .length = 21 },
    .{ .bits = 0x3ffffe8, .length = 26 },
    .{ .bits = 0x3ffffe9, .length = 26 },
    .{ .bits = 0xffffffd, .length = 28 },
    .{ .bits = 0x7ffffe3, .length = 27 },
    .{ .bits = 0x7ffffe4, .length = 27 },
    .{ .bits = 0x7ffffe5, .length = 27 },
    .{ .bits = 0xfffec, .length = 20 },
    .{ .bits = 0xfffff3, .length = 24 },
    .{ .bits = 0xfffed, .length = 20 },
    .{ .bits = 0x1fffe6, .length = 21 },
    .{ .bits = 0x3fffe9, .length = 22 },
    .{ .bits = 0x1fffe7, .length = 21 },
    .{ .bits = 0x1fffe8, .length = 21 },
    .{ .bits = 0x7ffff3, .length = 23 },
    .{ .bits = 0x3fffea, .length = 22 },
    .{ .bits = 0x3fffeb, .length = 22 },
    .{ .bits = 0x1ffffee, .length = 25 },
    .{ .bits = 0x1ffffef, .length = 25 },
    .{ .bits = 0xfffff4, .length = 24 },
    .{ .bits = 0xfffff5, .length = 24 },
    .{ .bits = 0x3ffffea, .length = 26 },
    .{ .bits = 0x7ffff4, .length = 23 },
    .{ .bits = 0x3ffffeb, .length = 26 },
    .{ .bits = 0x7ffffe6, .length = 27 },
    .{ .bits = 0x3ffffec, .length = 26 },
    .{ .bits = 0x3ffffed, .length = 26 },
    .{ .bits = 0x7ffffe7, .length = 27 },
    .{ .bits = 0x7ffffe8, .length = 27 },
    .{ .bits = 0x7ffffe9, .length = 27 },
    .{ .bits = 0x7ffffea, .length = 27 },
    .{ .bits = 0x7ffffeb, .length = 27 },
    .{ .bits = 0xffffffe, .length = 28 },
    .{ .bits = 0x7ffffec, .length = 27 },
    .{ .bits = 0x7ffffed, .length = 27 },
    .{ .bits = 0x7ffffee, .length = 27 },
    .{ .bits = 0x7ffffef, .length = 27 },
    .{ .bits = 0x7fffff0, .length = 27 },
    .{ .bits = 0x3ffffee, .length = 26 },
    .{ .bits = 0x3fffffff, .length = 30 },
};

pub const HpackDecoder = struct {
    allocator: std.mem.Allocator,
    config: HpackDecoderConfig,
    dynamic: std.ArrayListUnmanaged(DynamicEntry) = .empty,
    dynamic_bytes: usize = 0,

    pub fn init(allocator: std.mem.Allocator, config: HpackDecoderConfig) HpackError!HpackDecoder {
        try config.validate();
        return .{ .allocator = allocator, .config = config };
    }

    pub fn deinit(self: *HpackDecoder) void {
        self.clearDynamic();
        self.dynamic.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn decode(self: *HpackDecoder, block: []const u8) HpackError!HpackHeaderList {
        var result = HpackHeaderList{ .allocator = self.allocator };
        errdefer result.deinit();
        var cursor: usize = 0;
        var seen_header = false;
        while (cursor < block.len) {
            const first = block[cursor];
            if (first & 0x80 != 0) {
                seen_header = true;
                const index = try decodeInteger(block, &cursor, 7);
                const entry = try self.lookup(index);
                try result.append(self.config, entry.name, entry.value);
            } else if (first & 0x40 != 0) {
                seen_header = true;
                const name = try self.decodeName(block, &cursor, 6);
                defer self.allocator.free(name);
                const value = try self.decodeString(block, &cursor);
                defer self.allocator.free(value);
                try result.append(self.config, name, value);
                try self.insertDynamic(name, value);
            } else if (first & 0x20 != 0) {
                if (seen_header) return error.DynamicTableSizeUpdateAfterHeader;
                const size = try decodeInteger(block, &cursor, 5);
                if (size > self.config.maximum_dynamic_table_bytes) return error.DynamicTableSizeExceeded;
                self.resizeDynamic(size);
            } else {
                seen_header = true;
                const prefix: u3 = 4;
                const name = try self.decodeName(block, &cursor, prefix);
                defer self.allocator.free(name);
                const value = try self.decodeString(block, &cursor);
                defer self.allocator.free(value);
                try result.append(self.config, name, value);
            }
        }
        return result;
    }

    fn decodeName(self: *const HpackDecoder, input: []const u8, cursor: *usize, comptime prefix: u3) HpackError![]u8 {
        const index = try decodeInteger(input, cursor, prefix);
        if (index == 0) return self.decodeString(input, cursor);
        return self.allocator.dupe(u8, (try self.lookup(index)).name);
    }

    fn decodeString(self: *const HpackDecoder, input: []const u8, cursor: *usize) HpackError![]u8 {
        if (cursor.* == input.len) return error.Incomplete;
        const huffman = input[cursor.*] & 0x80 != 0;
        const length = try decodeInteger(input, cursor, 7);
        if (length > input.len - cursor.*) return error.Incomplete;
        const source = input[cursor.* .. cursor.* + length];
        cursor.* += length;
        return if (huffman) self.decodeHuffman(source) else self.allocator.dupe(u8, source);
    }

    fn decodeHuffman(self: *const HpackDecoder, source: []const u8) HpackError![]u8 {
        var output: std.ArrayListUnmanaged(u8) = .empty;
        errdefer output.deinit(self.allocator);
        var bits: u32 = 0;
        var bit_count: u8 = 0;
        for (source) |byte| {
            var shift: u4 = 8;
            while (shift != 0) {
                shift -= 1;
                bits = (bits << 1) | ((byte >> @as(u3, @intCast(shift))) & 1);
                bit_count += 1;
                var prefix = false;
                var symbol: ?usize = null;
                for (huffman_codes, 0..) |candidate, index| {
                    if (candidate.length < bit_count) continue;
                    if ((candidate.bits >> @as(u5, @intCast(candidate.length - bit_count))) != bits) continue;
                    prefix = true;
                    if (candidate.length == bit_count) {
                        symbol = index;
                        break;
                    }
                }
                if (!prefix) return error.InvalidHuffman;
                if (symbol) |value| {
                    if (value == huffman_codes.len) return error.InvalidHuffman;
                    if (output.items.len == self.config.maximum_header_list_bytes) return error.HeaderListTooLarge;
                    try output.append(self.allocator, @intCast(value));
                    bits = 0;
                    bit_count = 0;
                }
            }
        }
        if (bit_count != 0 and (bit_count > 7 or bits != (@as(u32, 1) << @as(u5, @intCast(bit_count))) - 1)) return error.InvalidHuffman;
        return output.toOwnedSlice(self.allocator);
    }

    fn lookup(self: *const HpackDecoder, index: usize) HpackError!HpackHeader {
        if (index == 0) return error.InvalidIndex;
        if (index <= static_table.len) return static_table[index - 1];
        const dynamic_index = index - static_table.len - 1;
        if (dynamic_index >= self.dynamic.items.len) return error.InvalidIndex;
        const entry = self.dynamic.items[dynamic_index];
        return .{ .name = entry.name, .value = entry.value };
    }

    fn insertDynamic(self: *HpackDecoder, name: []const u8, value: []const u8) HpackError!void {
        const name_and_value = std.math.add(usize, name.len, value.len) catch return error.HeaderListTooLarge;
        const bytes = std.math.add(usize, 32, name_and_value) catch return error.HeaderListTooLarge;
        if (bytes > self.config.maximum_dynamic_table_bytes) {
            self.clearDynamic();
            return;
        }
        self.evictTo(bytes);
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);
        try self.dynamic.insert(self.allocator, 0, .{ .name = owned_name, .value = owned_value, .bytes = bytes });
        self.dynamic_bytes += bytes;
    }

    fn resizeDynamic(self: *HpackDecoder, maximum: usize) void {
        while (self.dynamic_bytes > maximum) self.evictOne();
    }

    fn evictTo(self: *HpackDecoder, incoming: usize) void {
        while (self.dynamic_bytes > self.config.maximum_dynamic_table_bytes - incoming) self.evictOne();
    }

    fn evictOne(self: *HpackDecoder) void {
        var entry = self.dynamic.pop() orelse return;
        self.dynamic_bytes -= entry.bytes;
        entry.deinit(self.allocator);
    }

    fn clearDynamic(self: *HpackDecoder) void {
        while (self.dynamic.items.len != 0) self.evictOne();
    }
};

fn decodeInteger(input: []const u8, cursor: *usize, comptime prefix: u3) HpackError!usize {
    if (cursor.* == input.len) return error.Incomplete;
    const mask: u8 = (@as(u8, 1) << prefix) - 1;
    var value: usize = input[cursor.*] & mask;
    cursor.* += 1;
    if (value < mask) return value;
    var multiplier: usize = 1;
    while (true) {
        if (cursor.* == input.len) return error.Incomplete;
        const byte = input[cursor.*];
        cursor.* += 1;
        const remainder: usize = byte & 0x7f;
        if (remainder > (std.math.maxInt(usize) - value) / multiplier) return error.IntegerOverflow;
        value += remainder * multiplier;
        if (byte & 0x80 == 0) return value;
        if (multiplier > std.math.maxInt(usize) / 128) return error.IntegerOverflow;
        multiplier *= 128;
    }
}

test "HPACK decodes curl-compatible indexed, dynamic, and Huffman literals" {
    var decoder = try HpackDecoder.init(std.testing.allocator, .{});
    defer decoder.deinit();
    var headers = try decoder.decode("\x82\x86\x41\x8b\x08\x9d\x5c\x0b\x81\x70\xdc\x69\xb7\x9f\x0f\x04\x85\x62\xbb\x63\xa0\xc4\x7a\x88\x25\xb6\x50\xc3\xcb\xba\xb8\x7f\x53\x03\x2a\x2f\x2a");
    defer headers.deinit();
    try std.testing.expectEqual(@as(usize, 6), headers.entries.items.len);
    try std.testing.expectEqualStrings("127.0.0.1:45891", headers.entries.items[2].value);
    try std.testing.expectEqualStrings("/public", headers.entries.items[3].value);
    try std.testing.expectEqualStrings("curl/8.7.1", headers.entries.items[4].value);
    try std.testing.expectEqualStrings("*/*", headers.entries.items[5].value);
}

test "HPACK rejects dangling Huffman prefixes and invalid dynamic indexes" {
    var decoder = try HpackDecoder.init(std.testing.allocator, .{});
    defer decoder.deinit();
    try std.testing.expectError(error.InvalidHuffman, decoder.decode("\x01\x81\x00"));
    try std.testing.expectError(error.InvalidIndex, decoder.decode("\xbe"));
}
