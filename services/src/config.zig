const std = @import("std");
const services = @import("unpolished-peas-services");

const max_config_bytes = 64 * 1024;

pub const RuntimeConfig = struct {
    bind_address: []const u8,
    port: u16,
    secrets_path: []const u8,

    pub fn endpoint(self: RuntimeConfig) services.Endpoint {
        return .{ .host = self.bind_address, .port = self.port };
    }
};

pub fn load(allocator: std.mem.Allocator, path: []const u8) !RuntimeConfig {
    const source = try std.fs.cwd().readFileAllocOptions(allocator, path, max_config_bytes, null, .of(u8), 0);
    defer allocator.free(source);
    var diagnostics: std.zon.parse.Diagnostics = .{};
    defer diagnostics.deinit(allocator);
    const config = std.zon.parse.fromSlice(RuntimeConfig, allocator, source, &diagnostics, .{ .ignore_unknown_fields = false }) catch return error.InvalidServiceConfig;
    errdefer std.zon.parse.free(allocator, config);
    try validate(config);
    return config;
}

pub fn deinit(allocator: std.mem.Allocator, config: RuntimeConfig) void {
    std.zon.parse.free(allocator, config);
}

pub fn validate(config: RuntimeConfig) !void {
    if (config.bind_address.len == 0) return error.InvalidBindAddress;
    _ = std.net.Address.parseIp(config.bind_address, config.port) catch return error.InvalidBindAddress;
    if (!hasExplicitSecretPath(config.secrets_path)) return error.SecretPathMustBeAbsolute;
}

fn hasExplicitSecretPath(path: []const u8) bool {
    if (path.len != 0 and path[0] == '/') return true;
    return path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '/' or path[2] == '\\');
}

test "runtime config requires an explicit secret path" {
    try std.testing.expectError(error.SecretPathMustBeAbsolute, validate(.{ .bind_address = "127.0.0.1", .port = 48080, .secrets_path = "local.secret" }));
}

test "runtime config accepts a local bind with an explicit secret path" {
    try validate(.{ .bind_address = "127.0.0.1", .port = 48080, .secrets_path = "/var/lib/unpolished-peas/local.secret" });
}
