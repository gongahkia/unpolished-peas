const std = @import("std");

const max_source_bytes = 8 * 1024 * 1024;
const roots = [_][]const u8{ "examples", "fixtures", "templates" };

const Import = struct {
    module: []u8,
    path: []u8,
    symbols: std.ArrayListUnmanaged([]u8) = .{},

    fn deinit(self: *Import, allocator: std.mem.Allocator) void {
        allocator.free(self.module);
        allocator.free(self.path);
        for (self.symbols.items) |symbol| allocator.free(symbol);
        self.symbols.deinit(allocator);
        self.* = undefined;
    }
};

const Source = struct {
    path: []u8,
    imports: std.ArrayListUnmanaged(Import) = .{},

    fn deinit(self: *Source, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        for (self.imports.items) |*entry| entry.deinit(allocator);
        self.imports.deinit(allocator);
        self.* = undefined;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const root = args.next() orelse return usage();
    const output_path = args.next() orelse return usage();
    const check = if (args.next()) |argument| std.mem.eql(u8, argument, "--check") else false;
    if (args.next() != null) return usage();
    const inventory = try generate(allocator, root);
    defer allocator.free(inventory);
    if (!check) {
        try std.fs.File.stdout().writeAll(inventory);
        return;
    }
    const existing = try std.fs.cwd().readFileAlloc(allocator, output_path, max_source_bytes);
    defer allocator.free(existing);
    if (!std.mem.eql(u8, existing, inventory)) {
        std.debug.print("public import inventory is stale: zig build public-import-inventory > {s}\n", .{output_path});
        return error.StaleInventory;
    }
}

pub fn generate(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    var paths = std.ArrayListUnmanaged([]u8){};
    defer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }
    for (roots) |directory| try collectPaths(allocator, root, directory, &paths);
    std.sort.pdq([]u8, paths.items, {}, lessThanString);

    var sources = std.ArrayListUnmanaged(Source){};
    defer {
        for (sources.items) |*source| source.deinit(allocator);
        sources.deinit(allocator);
    }
    for (paths.items) |path| {
        const source = try std.fs.cwd().readFileAlloc(allocator, path, max_source_bytes);
        defer allocator.free(source);
        var entry = Source{ .path = try allocator.dupe(u8, path) };
        errdefer entry.deinit(allocator);
        try scanImports(allocator, source, &entry.imports);
        try sources.append(allocator, entry);
    }
    return encode(allocator, sources.items);
}

fn collectPaths(allocator: std.mem.Allocator, root: []const u8, directory: []const u8, paths: *std.ArrayListUnmanaged([]u8)) !void {
    const full_path = try std.fs.path.join(allocator, &.{ root, directory });
    defer allocator.free(full_path);
    var dir = try std.fs.cwd().openDir(full_path, .{ .iterate = true });
    defer dir.close();
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file or ignoredPath(entry.path) or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        try paths.append(allocator, try std.fs.path.join(allocator, &.{ directory, entry.path }));
    }
}

fn scanImports(allocator: std.mem.Allocator, source: []const u8, imports: *std.ArrayListUnmanaged(Import)) !void {
    const code = try codeMask(allocator, source);
    defer allocator.free(code);
    const marker = "@import(\"";
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, source, cursor, marker)) |start| {
        cursor = start + marker.len;
        if (code[start] == ' ') continue;
        const module_start = start + marker.len;
        const module_end = std.mem.indexOfScalarPos(u8, source, module_start, '"') orelse return error.InvalidImport;
        if (module_end + 1 >= source.len or source[module_end + 1] != ')') return error.InvalidImport;
        cursor = module_end + 1;
        const module = source[module_start..module_end];
        if (!isPublicModule(module)) continue;
        const alias = declarationAlias(code, start) orelse return error.InvalidImport;
        const path = try memberPath(allocator, source, code, module_end + 2);
        errdefer allocator.free(path);
        var entry = Import{
            .module = try allocator.dupe(u8, module),
            .path = path,
        };
        errdefer entry.deinit(allocator);
        try collectSymbols(allocator, code, alias, &entry.symbols);
        std.sort.pdq([]u8, entry.symbols.items, {}, lessThanString);
        try imports.append(allocator, entry);
    }
    std.sort.pdq(Import, imports.items, {}, lessThanImport);
}

fn codeMask(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const result = try allocator.dupe(u8, source);
    var index: usize = 0;
    while (index < result.len) {
        if (index + 1 < result.len and result[index] == '/' and result[index + 1] == '/') {
            while (index < result.len and result[index] != '\n') : (index += 1) result[index] = ' ';
            continue;
        }
        if (result[index] != '"') {
            index += 1;
            continue;
        }
        result[index] = ' ';
        index += 1;
        while (index < result.len) : (index += 1) {
            const byte = result[index];
            result[index] = ' ';
            if (byte == '\\' and index + 1 < result.len) {
                index += 1;
                result[index] = ' ';
            } else if (byte == '"') {
                index += 1;
                break;
            }
        }
    }
    return result;
}

fn declarationAlias(code: []const u8, import_start: usize) ?[]const u8 {
    var line_start = import_start;
    while (line_start > 0 and code[line_start - 1] != '\n') : (line_start -= 1) {}
    const declaration = code[line_start..import_start];
    const const_start = std.mem.lastIndexOf(u8, declaration, "const ") orelse return null;
    var name_start = line_start + const_start + "const ".len;
    while (name_start < import_start and isWhitespace(code[name_start])) : (name_start += 1) {}
    var name_end = name_start;
    while (name_end < import_start and isIdentifier(code[name_end])) : (name_end += 1) {}
    if (name_end == name_start) return null;
    var equals = name_end;
    while (equals < import_start and isWhitespace(code[equals])) : (equals += 1) {}
    if (equals >= import_start or code[equals] != '=') return null;
    return code[name_start..name_end];
}

fn memberPath(allocator: std.mem.Allocator, source: []const u8, code: []const u8, start: usize) ![]u8 {
    var path = std.ArrayList(u8).empty;
    errdefer path.deinit(allocator);
    var index = start;
    while (index < code.len and isWhitespace(code[index])) : (index += 1) {}
    while (index < code.len and code[index] == '.') {
        index += 1;
        const member_start = index;
        while (index < code.len and isIdentifier(code[index])) : (index += 1) {}
        if (member_start == index) return error.InvalidImport;
        if (path.items.len != 0) try path.append(allocator, '.');
        try path.appendSlice(allocator, source[member_start..index]);
        while (index < code.len and isWhitespace(code[index])) : (index += 1) {}
    }
    return path.toOwnedSlice(allocator);
}

fn collectSymbols(allocator: std.mem.Allocator, code: []const u8, alias: []const u8, symbols: *std.ArrayListUnmanaged([]u8)) !void {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, code, cursor, alias)) |start| {
        cursor = start + alias.len;
        if ((start > 0 and isIdentifier(code[start - 1])) or cursor >= code.len or code[cursor] != '.') continue;
        const symbol_start = cursor + 1;
        var symbol_end = symbol_start;
        while (symbol_end < code.len and isIdentifier(code[symbol_end])) : (symbol_end += 1) {}
        if (symbol_start == symbol_end) continue;
        const symbol = code[symbol_start..symbol_end];
        var found = false;
        for (symbols.items) |existing| if (std.mem.eql(u8, existing, symbol)) {
            found = true;
            break;
        };
        if (!found) try symbols.append(allocator, try allocator.dupe(u8, symbol));
    }
}

fn encode(allocator: std.mem.Allocator, sources: []const Source) ![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    const writer = output.writer(allocator);
    try writer.writeAll("{\n  \"version\": 1,\n  \"sources\": [\n");
    for (sources, 0..) |source, source_index| {
        try writer.writeAll("    {\"path\": ");
        try writeString(writer, source.path);
        try writer.writeAll(", \"imports\": [");
        for (source.imports.items, 0..) |entry, import_index| {
            if (import_index != 0) try writer.writeAll(", ");
            try writer.writeAll("{\"module\": ");
            try writeString(writer, entry.module);
            try writer.writeAll(", \"path\": ");
            try writeString(writer, entry.path);
            try writer.writeAll(", \"symbols\": [");
            for (entry.symbols.items, 0..) |symbol, symbol_index| {
                if (symbol_index != 0) try writer.writeAll(", ");
                try writeString(writer, symbol);
            }
            try writer.writeAll("]}");
        }
        try writer.writeAll("]}");
        if (source_index + 1 != sources.len) try writer.writeByte(',');
        try writer.writeByte('\n');
    }
    try writer.writeAll("  ]\n}\n");
    return output.toOwnedSlice(allocator);
}

fn writeString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}

fn isPublicModule(module: []const u8) bool {
    return std.mem.eql(u8, module, "unpolished-peas") or std.mem.startsWith(u8, module, "unpolished-peas-");
}

fn isIdentifier(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn isWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}

fn ignoredPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, ".zig-cache/") or
        std.mem.startsWith(u8, path, "zig-out/") or
        std.mem.indexOf(u8, path, "/.zig-cache/") != null or
        std.mem.indexOf(u8, path, "/zig-out/") != null;
}

fn lessThanString(_: void, lhs: []u8, rhs: []u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

fn lessThanImport(_: void, lhs: Import, rhs: Import) bool {
    const module_order = std.mem.order(u8, lhs.module, rhs.module);
    return if (module_order == .eq) std.mem.order(u8, lhs.path, rhs.path) == .lt else module_order == .lt;
}

fn usage() error{InvalidArguments} {
    std.debug.print("usage: public_import_inventory <root> <output> [--check]\n", .{});
    return error.InvalidArguments;
}

test "inventory records root and namespaced imports" {
    const source =
        \\const up = @import("unpolished-peas");
        \\const core = @import("unpolished-peas").api.core;
        \\const sdl = @import("unpolished-peas-sdl3");
        \\const point: core.Vec2 = up.Vec2{};
        \\try sdl.play(.{}, struct {});
    ;
    var imports = std.ArrayListUnmanaged(Import){};
    defer {
        for (imports.items) |*entry| entry.deinit(std.testing.allocator);
        imports.deinit(std.testing.allocator);
    }
    try scanImports(std.testing.allocator, source, &imports);
    try std.testing.expectEqual(@as(usize, 3), imports.items.len);
    try std.testing.expectEqualStrings("unpolished-peas", imports.items[0].module);
    try std.testing.expectEqualStrings("", imports.items[0].path);
    try std.testing.expectEqualStrings("Vec2", imports.items[0].symbols.items[0]);
    try std.testing.expectEqualStrings("api.core", imports.items[1].path);
    try std.testing.expectEqualStrings("Vec2", imports.items[1].symbols.items[0]);
    try std.testing.expectEqualStrings("unpolished-peas-sdl3", imports.items[2].module);
    try std.testing.expectEqualStrings("play", imports.items[2].symbols.items[0]);
}

test "inventory ignores comments and strings" {
    const source =
        \\// const ignored = @import("unpolished-peas");
        \\const up = @import("unpolished-peas");
        \\const message = "up.Color";
        \\const color = up.Color;
    ;
    var imports = std.ArrayListUnmanaged(Import){};
    defer {
        for (imports.items) |*entry| entry.deinit(std.testing.allocator);
        imports.deinit(std.testing.allocator);
    }
    try scanImports(std.testing.allocator, source, &imports);
    try std.testing.expectEqual(@as(usize, 1), imports.items.len);
    try std.testing.expectEqual(@as(usize, 1), imports.items[0].symbols.items.len);
    try std.testing.expectEqualStrings("Color", imports.items[0].symbols.items[0]);
}
