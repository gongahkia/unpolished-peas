const std = @import("std");
const resolver = @import("extension_resolver.zig");

const fixture_path = "fixtures/extensions/test-matrix.zon";

const Fixture = struct {
    format: []const u8,
    version: u32,
    core_releases: []const []const u8,
    packages: []const PackageDefinition,
};

const PackageDefinition = struct {
    name: []const u8,
    version: []const u8,
    core_range: []const u8,
    target: []const u8,
    consumer: []const u8,
};

const Pair = struct {
    core: []u8,
    package: []u8,
    target: []u8,
    consumer: []u8,

    fn deinit(self: *Pair, allocator: std.mem.Allocator) void {
        allocator.free(self.core);
        allocator.free(self.package);
        allocator.free(self.target);
        allocator.free(self.consumer);
        self.* = undefined;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    const pairs = try resolveFixture(allocator, fixture_path);
    defer deinitPairs(allocator, pairs);
    var buffer: [1024]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buffer);
    const out = &writer.interface;
    for (pairs) |pair| try out.print("{s}\t{s}\t{s}\t{s}\n", .{ pair.core, pair.package, pair.target, pair.consumer });
    try out.flush();
}

fn resolveFixture(allocator: std.mem.Allocator, path: []const u8) ![]Pair {
    const source = try std.fs.cwd().readFileAllocOptions(allocator, path, 64 * 1024, null, .of(u8), 0);
    defer allocator.free(source);
    return resolveSource(allocator, source);
}

fn resolveSource(allocator: std.mem.Allocator, source: [:0]const u8) ![]Pair {
    var diagnostics: std.zon.parse.Diagnostics = .{};
    defer diagnostics.deinit(allocator);
    const fixture = std.zon.parse.fromSlice(Fixture, allocator, source, &diagnostics, .{ .ignore_unknown_fields = false }) catch return error.InvalidExtensionMatrix;
    defer std.zon.parse.free(allocator, fixture);
    if (!std.mem.eql(u8, fixture.format, "unpolished-peas-extension-test-matrix") or fixture.version != 1 or fixture.core_releases.len == 0 or fixture.packages.len == 0) return error.InvalidExtensionMatrix;
    var packages = std.ArrayListUnmanaged(resolver.Package){};
    defer packages.deinit(allocator);
    for (fixture.packages) |package| {
        if (package.name.len == 0 or package.target.len == 0 or !validConsumerPath(package.consumer)) return error.InvalidExtensionMatrix;
        {
            var consumer = std.fs.cwd().openDir(package.consumer, .{}) catch return error.InvalidExtensionMatrix;
            defer consumer.close();
            consumer.access("build.zig", .{}) catch return error.InvalidExtensionMatrix;
        }
        try packages.append(allocator, .{ .name = package.name, .version = package.version, .core_range = package.core_range });
    }
    var pairs = std.ArrayListUnmanaged(Pair){};
    errdefer {
        for (pairs.items) |*pair| pair.deinit(allocator);
        pairs.deinit(allocator);
    }
    for (fixture.core_releases) |core| for (fixture.packages) |package| {
        const requirements = [_]resolver.Requirement{.{ .name = package.name, .range = package.version }};
        var lock = try resolver.resolve(allocator, .{ .core_version = core, .requirements = &requirements, .packages = packages.items });
        defer lock.deinit();
        if (lock.packages.len != 1 or !std.mem.eql(u8, lock.packages[0].name, package.name) or !std.mem.eql(u8, lock.packages[0].version, package.version)) return error.InvalidExtensionMatrix;
        try pairs.append(allocator, .{
            .core = try allocator.dupe(u8, core),
            .package = try allocator.dupe(u8, package.name),
            .target = try allocator.dupe(u8, package.target),
            .consumer = try allocator.dupe(u8, package.consumer),
        });
    };
    sortPairs(pairs.items);
    return pairs.toOwnedSlice(allocator);
}

fn deinitPairs(allocator: std.mem.Allocator, pairs: []Pair) void {
    for (pairs) |*pair| pair.deinit(allocator);
    allocator.free(pairs);
}

fn sortPairs(pairs: []Pair) void {
    var index: usize = 1;
    while (index < pairs.len) : (index += 1) {
        var cursor = index;
        while (cursor > 0 and pairLessThan(pairs[cursor], pairs[cursor - 1])) : (cursor -= 1) {
            const swap = pairs[cursor - 1];
            pairs[cursor - 1] = pairs[cursor];
            pairs[cursor] = swap;
        }
    }
}

fn pairLessThan(lhs: Pair, rhs: Pair) bool {
    const core_order = std.mem.order(u8, lhs.core, rhs.core);
    return if (core_order == .eq) std.mem.order(u8, lhs.package, rhs.package) == .lt else core_order == .lt;
}

fn validConsumerPath(value: []const u8) bool {
    if (value.len == 0 or std.fs.path.isAbsolute(value)) return false;
    var segments = std.mem.splitScalar(u8, value, '/');
    while (segments.next()) |segment| if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
    return true;
}

fn assertMatrixFixture(pairs: []const Pair, fixture: []const u8) !void {
    var lines = std.mem.splitScalar(u8, fixture, '\n');
    for (pairs) |pair| {
        var buffer: [256]u8 = undefined;
        const line = try std.fmt.bufPrint(&buffer, "{s}\t{s}\t{s}\t{s}", .{ pair.core, pair.package, pair.target, pair.consumer });
        try std.testing.expectEqualStrings(line, lines.next() orelse return error.InvalidFixture);
    }
    while (lines.next()) |line| try std.testing.expectEqualStrings("", line);
}

test "extension matrix resolves every declared package and core release" {
    const pairs = try resolveFixture(std.testing.allocator, fixture_path);
    defer deinitPairs(std.testing.allocator, pairs);
    const fixture = try std.fs.cwd().readFileAlloc(std.testing.allocator, "fixtures/extensions/test-matrix.lock", 4096);
    defer std.testing.allocator.free(fixture);
    try assertMatrixFixture(pairs, fixture);
}

test "extension matrix rejects malformed fixture metadata" {
    const source: [:0]const u8 =
        \\ .{ .format = "unpolished-peas-extension-test-matrix", .version = 2, .core_releases = .{ "1.0.0" }, .packages = .{ .{ .name = "physics", .version = "1.0.0", .core_range = "^1.0.0", .target = "test-box2d", .consumer = "fixtures/physics-package" } } }
    ;
    try std.testing.expectError(error.InvalidExtensionMatrix, resolveSource(std.testing.allocator, source));
}

test "extension matrix rejects unsafe or missing consumer fixtures" {
    const unsafe: [:0]const u8 =
        \\ .{ .format = "unpolished-peas-extension-test-matrix", .version = 1, .core_releases = .{ "1.0.0" }, .packages = .{ .{ .name = "physics", .version = "1.0.0", .core_range = "^1.0.0", .target = "test-box2d", .consumer = "../outside" } } }
    ;
    const missing: [:0]const u8 =
        \\ .{ .format = "unpolished-peas-extension-test-matrix", .version = 1, .core_releases = .{ "1.0.0" }, .packages = .{ .{ .name = "physics", .version = "1.0.0", .core_range = "^1.0.0", .target = "test-box2d", .consumer = "fixtures/missing-consumer" } } }
    ;
    try std.testing.expectError(error.InvalidExtensionMatrix, resolveSource(std.testing.allocator, unsafe));
    try std.testing.expectError(error.InvalidExtensionMatrix, resolveSource(std.testing.allocator, missing));
}
