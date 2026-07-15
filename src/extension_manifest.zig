const std = @import("std");
const resolver = @import("extension_resolver.zig");

pub const Source = struct {
    format: []const u8,
    version: u32,
    name: []const u8,
    package_version: []const u8,
    core_range: []const u8,
    modules: []const Module,
    tests: []const Test,
    hook: ?Hook = null,
};

pub const Module = struct {
    name: []const u8,
    path: []const u8,
};

pub const Test = struct {
    name: []const u8,
    target: []const u8,
    path: []const u8,
};

pub const Hook = struct {
    name: []const u8,
    script: []const u8,
};

pub fn validateFile(allocator: std.mem.Allocator, path: []const u8) !void {
    const source = try std.fs.cwd().readFileAllocOptions(allocator, path, 64 * 1024, null, .of(u8), 0);
    defer allocator.free(source);
    const parent = std.fs.path.dirname(path) orelse return error.InvalidManifest;
    var directory = try std.fs.cwd().openDir(parent, .{});
    defer directory.close();
    try validateSource(allocator, source, directory);
}

pub fn validateSource(allocator: std.mem.Allocator, source: [:0]const u8, directory: std.fs.Dir) !void {
    var diagnostics: std.zon.parse.Diagnostics = .{};
    defer diagnostics.deinit(allocator);
    const manifest = std.zon.parse.fromSlice(Source, allocator, source, &diagnostics, .{ .ignore_unknown_fields = false }) catch return error.InvalidManifest;
    defer std.zon.parse.free(allocator, manifest);
    try validate(allocator, manifest, directory);
}

pub fn validate(allocator: std.mem.Allocator, manifest: Source, directory: std.fs.Dir) !void {
    if (!std.mem.eql(u8, manifest.format, "unpolished-peas-extension") or manifest.version != 1) return error.InvalidManifest;
    if (!validName(manifest.name) or !validVersion(manifest.package_version)) return error.InvalidManifest;
    const package = [_]resolver.Package{.{ .name = manifest.name, .version = manifest.package_version, .core_range = manifest.core_range }};
    _ = resolver.resolve(allocator, .{ .core_version = "1.0.0", .requirements = &.{}, .packages = &package }) catch return error.InvalidManifest;
    if (manifest.modules.len == 0 or manifest.tests.len == 0) return error.InvalidManifest;
    if (manifest.hook) |hook| {
        if (!validName(hook.name) or !validSourcePath(hook.script)) return error.InvalidManifest;
        try directory.access(hook.script, .{});
    }
    for (manifest.modules, 0..) |module, index| {
        if (!validName(module.name) or !validSourcePath(module.path)) return error.InvalidManifest;
        try directory.access(module.path, .{});
        for (manifest.modules[index + 1 ..]) |other| if (std.mem.eql(u8, module.name, other.name)) return error.InvalidManifest;
    }
    for (manifest.tests, 0..) |test_entry, index| {
        if (!validName(test_entry.name) or !validName(test_entry.target) or !validSourcePath(test_entry.path)) return error.InvalidManifest;
        try directory.access(test_entry.path, .{});
        for (manifest.tests[index + 1 ..]) |other| if (std.mem.eql(u8, test_entry.name, other.name) or std.mem.eql(u8, test_entry.target, other.target)) return error.InvalidManifest;
    }
}

fn validName(value: []const u8) bool {
    if (value.len == 0 or value.len > 64 or value[0] == '-' or value[value.len - 1] == '-') return false;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-') return false;
    return true;
}

fn validVersion(value: []const u8) bool {
    _ = resolver.Version.parse(value) catch return false;
    return true;
}

fn validSourcePath(value: []const u8) bool {
    return safePath(value) and std.mem.endsWith(u8, value, ".zig");
}

fn safePath(value: []const u8) bool {
    if (value.len == 0 or std.fs.path.isAbsolute(value)) return false;
    var segments = std.mem.splitScalar(u8, value, '/');
    while (segments.next()) |segment| if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
    return true;
}

test "extension manifests validate package identity, modules, tests, and hook" {
    try validateFile(std.testing.allocator, "fixtures/extensions/manifest-valid/extension.zon");
    try validateFile(std.testing.allocator, "packages/effects/extension.zon");
    try validateFile(std.testing.allocator, "packages/networking/extension.zon");
    try validateFile(std.testing.allocator, "packages/physics/extension.zon");
    try validateFile(std.testing.allocator, "packages/ui/extension.zon");
}

test "extension manifest rejects invalid identity and paths" {
    try std.testing.expectError(error.InvalidManifest, validateFile(std.testing.allocator, "fixtures/extensions/manifest-invalid/invalid-name.zon"));
    try std.testing.expectError(error.InvalidManifest, validateFile(std.testing.allocator, "fixtures/extensions/manifest-invalid/invalid-path.zon"));
    try std.testing.expectError(error.InvalidManifest, validateFile(std.testing.allocator, "fixtures/extensions/manifest-invalid/invalid-hook.zon"));
}
