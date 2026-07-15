const std = @import("std");
const services = @import("unpolished-peas-services");

const max_config_bytes = 64 * 1024;

pub const RuntimeConfig = struct {
    bind_address: []const u8,
    port: u16,
    secrets_path: []const u8,
    database_url_environment: []const u8,
    relay_address: []const u8,
    relay_port: u16,
    engine_runtime_telemetry_enabled: bool,

    pub fn endpoint(self: RuntimeConfig) services.Endpoint {
        return .{ .host = self.bind_address, .port = self.port };
    }

    pub fn relayEndpoint(self: RuntimeConfig) services.Endpoint {
        return .{ .host = self.relay_address, .port = self.relay_port };
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
    if (!isEnvironmentName(config.database_url_environment)) return error.InvalidDatabaseUrlEnvironment;
    _ = std.net.Address.parseIp(config.relay_address, config.relay_port) catch return error.InvalidRelayEndpoint;
    if (config.engine_runtime_telemetry_enabled) return error.EngineRuntimeTelemetryMustBeDisabled;
}

fn hasExplicitSecretPath(path: []const u8) bool {
    if (path.len != 0 and path[0] == '/') return true;
    return path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '/' or path[2] == '\\');
}

fn isEnvironmentName(name: []const u8) bool {
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |character| if (!(std.ascii.isAlphanumeric(character) or character == '_')) return false;
    return true;
}

test "runtime config requires an explicit secret path" {
    try std.testing.expectError(error.SecretPathMustBeAbsolute, validate(.{ .bind_address = "127.0.0.1", .port = 48080, .secrets_path = "local.secret", .database_url_environment = "UP_SERVICES_DATABASE_URL", .relay_address = "127.0.0.1", .relay_port = 48081, .engine_runtime_telemetry_enabled = false }));
}

test "runtime config accepts a local bind with an explicit secret path" {
    const runtime_config = RuntimeConfig{ .bind_address = "127.0.0.1", .port = 48080, .secrets_path = "/var/lib/unpolished-peas/local.secret", .database_url_environment = "UP_SERVICES_DATABASE_URL", .relay_address = "127.0.0.1", .relay_port = 48081, .engine_runtime_telemetry_enabled = false };
    try validate(runtime_config);
    try std.testing.expectEqual(@as(u16, 48081), runtime_config.relayEndpoint().port);
}

test "runtime config rejects unsafe deployment settings" {
    try std.testing.expectError(error.InvalidDatabaseUrlEnvironment, validate(.{ .bind_address = "127.0.0.1", .port = 48080, .secrets_path = "/var/lib/unpolished-peas/local.secret", .database_url_environment = "UP_DATABASE_URL=value", .relay_address = "127.0.0.1", .relay_port = 48081, .engine_runtime_telemetry_enabled = false }));
    try std.testing.expectError(error.InvalidRelayEndpoint, validate(.{ .bind_address = "127.0.0.1", .port = 48080, .secrets_path = "/var/lib/unpolished-peas/local.secret", .database_url_environment = "UP_SERVICES_DATABASE_URL", .relay_address = "relay.internal", .relay_port = 48081, .engine_runtime_telemetry_enabled = false }));
    try std.testing.expectError(error.EngineRuntimeTelemetryMustBeDisabled, validate(.{ .bind_address = "127.0.0.1", .port = 48080, .secrets_path = "/var/lib/unpolished-peas/local.secret", .database_url_environment = "UP_SERVICES_DATABASE_URL", .relay_address = "127.0.0.1", .relay_port = 48081, .engine_runtime_telemetry_enabled = true }));
}
