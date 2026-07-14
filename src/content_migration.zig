const std = @import("std");
const catalog = @import("asset_catalog.zig");
const map_source = @import("map_source.zig");
const scene = @import("scene.zig");

pub const Kind = enum { scene, catalog, map };

pub const Result = struct {
    allocator: std.mem.Allocator,
    source: []u8,
    changed: bool,

    pub fn deinit(self: *Result) void {
        self.allocator.free(self.source);
        self.* = undefined;
    }
};

pub const Diagnostic = struct {
    line: usize = 1,
    column: usize = 1,
    message: []const u8 = "unsupported content version; run peas migrate <scene|catalog|map> <input> <output>",
};

pub fn migrate(allocator: std.mem.Allocator, kind: Kind, source: []const u8, diagnostic: *Diagnostic) !Result {
    const version = findVersion(source, diagnostic) catch return error.InvalidContentVersion;
    if (version == 1) {
        try validate(kind, allocator, source, diagnostic);
        return .{ .allocator = allocator, .source = try allocator.dupe(u8, source), .changed = false };
    }
    if (version != 0) {
        diagnostic.* = .{ .line = fieldLocation(source, "version").line, .column = fieldLocation(source, "version").column };
        return error.UnsupportedContentVersion;
    }
    const migrated = try replaceVersion(allocator, source);
    errdefer allocator.free(migrated);
    try validate(kind, allocator, migrated, diagnostic);
    return .{ .allocator = allocator, .source = migrated, .changed = true };
}

fn validate(kind: Kind, allocator: std.mem.Allocator, source: []const u8, diagnostic: *Diagnostic) !void {
    switch (kind) {
        .scene => {
            var inner = scene.Diagnostic{};
            var parsed = scene.parse(allocator, source, &inner) catch |err| {
                diagnostic.* = .{ .line = inner.line, .column = inner.column, .message = inner.message };
                return err;
            };
            parsed.deinit(allocator);
        },
        .catalog => {
            var inner = catalog.Diagnostic{};
            var parsed = catalog.parse(allocator, source, &inner) catch |err| {
                diagnostic.* = .{ .line = inner.line, .column = inner.column, .message = inner.message };
                return err;
            };
            parsed.deinit(allocator);
        },
        .map => {
            var inner = map_source.Diagnostic{};
            var parsed = map_source.parse(allocator, source, &inner) catch |err| {
                diagnostic.* = .{ .line = inner.line, .column = inner.column, .message = inner.message };
                return err;
            };
            parsed.deinit(allocator);
        },
    }
}

fn findVersion(source: []const u8, diagnostic: *Diagnostic) !u32 {
    const field = ".version = ";
    const start = std.mem.indexOf(u8, source, field) orelse {
        diagnostic.* = .{ .line = fieldLocation(source, "version").line, .column = fieldLocation(source, "version").column, .message = "content source requires a version field" };
        return error.InvalidContentVersion;
    };
    const value_start = start + field.len;
    var end = value_start;
    while (end < source.len and std.ascii.isDigit(source[end])) : (end += 1) {}
    return std.fmt.parseInt(u32, source[value_start..end], 10) catch {
        diagnostic.* = .{ .line = fieldLocation(source, "version").line, .column = fieldLocation(source, "version").column, .message = "content version must be an unsigned integer" };
        return error.InvalidContentVersion;
    };
}

fn replaceVersion(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const field = ".version = 0";
    const start = std.mem.indexOf(u8, source, field) orelse return error.InvalidContentVersion;
    var result = try std.ArrayList(u8).initCapacity(allocator, source.len);
    errdefer result.deinit(allocator);
    try result.appendSlice(allocator, source[0..start]);
    try result.appendSlice(allocator, ".version = 1");
    try result.appendSlice(allocator, source[start + field.len ..]);
    return result.toOwnedSlice(allocator);
}

fn fieldLocation(source: []const u8, field: []const u8) struct { line: usize, column: usize } {
    const offset = std.mem.indexOf(u8, source, field) orelse return .{ .line = 1, .column = 1 };
    var line: usize = 1;
    var column: usize = 1;
    for (source[0..offset]) |byte| {
        if (byte == '\n') {
            line += 1;
            column = 1;
        } else column += 1;
    }
    return .{ .line = line, .column = column };
}

test "content migration upgrades v0 idempotently without writing files" {
    const v0 =
        \\.{ .format = "unpolished-peas-scene", .version = 0, .metadata = .{ .name = "main", .tags = .{} }, .entities = .{} }
        \\
    ;
    var diagnostic = Diagnostic{};
    var first = try migrate(std.testing.allocator, .scene, v0, &diagnostic);
    defer first.deinit();
    try std.testing.expect(first.changed);
    try std.testing.expect(std.mem.indexOf(u8, first.source, ".version = 1") != null);
    var second = try migrate(std.testing.allocator, .scene, first.source, &diagnostic);
    defer second.deinit();
    try std.testing.expect(!second.changed);
    try std.testing.expectEqualStrings(first.source, second.source);
}

test "content migration reports unsupported versions with recovery guidance" {
    const source =
        \\.{ .format = "unpolished-peas-map", .version = 9, .metadata = .{ .name = "main", .projection = .orthogonal, .tile_width = 8, .tile_height = 8, .chunk_size = 8 }, .tilesets = .{}, .layers = .{} }
        \\
    ;
    var diagnostic = Diagnostic{};
    try std.testing.expectError(error.UnsupportedContentVersion, migrate(std.testing.allocator, .map, source, &diagnostic));
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, "peas migrate") != null);
}
