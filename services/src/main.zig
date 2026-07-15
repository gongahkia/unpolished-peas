const std = @import("std");
const config = @import("config.zig");
const health = @import("health.zig");

const max_http_request_bytes = 1_024;

const RuntimeDependencies = struct {
    allocator: std.mem.Allocator,
    runtime_config: config.RuntimeConfig,

    fn dependencies(self: *RuntimeDependencies) health.Dependencies {
        return .{ .context = self, .check_database_fn = database, .check_relay_fn = relay };
    }

    fn database(context: *anyopaque) !void {
        const self: *RuntimeDependencies = @ptrCast(@alignCast(context));
        var environment = std.process.getEnvMap(self.allocator) catch return error.DatabaseUnavailable;
        defer environment.deinit();
        const database_url = environment.get(self.runtime_config.database_url_environment) orelse return error.DatabaseUnavailable;
        if (database_url.len == 0) return error.DatabaseUnavailable;
        environment.put("PGDATABASE", database_url) catch return error.DatabaseUnavailable;
        environment.put("PGCONNECT_TIMEOUT", "2") catch return error.DatabaseUnavailable;
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "psql", "-X", "-v", "ON_ERROR_STOP=1", "-Atq", "-c", "SELECT 1;" },
            .env_map = &environment,
            .max_output_bytes = 1_024,
        }) catch return error.DatabaseUnavailable;
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        if (result.term != .Exited or result.term.Exited != 0 or !std.mem.eql(u8, std.mem.trim(u8, result.stdout, " \t\r\n"), "1")) return error.DatabaseUnavailable;
    }

    fn relay(context: *anyopaque) !void {
        const self: *RuntimeDependencies = @ptrCast(@alignCast(context));
        const address = std.net.Address.parseIp(self.runtime_config.relay_address, self.runtime_config.relay_port) catch return error.RelayUnavailable;
        const stream = std.net.tcpConnectToAddress(address) catch return error.RelayUnavailable;
        stream.close();
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const first = args.next() orelse return usage();
    if (std.mem.eql(u8, first, "help") or std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h")) return usage();
    if (!std.mem.eql(u8, first, "--config")) return usage();
    const config_path = args.next() orelse return usage();
    var once = false;
    if (args.next()) |argument| {
        if (!std.mem.eql(u8, argument, "--once") or args.next() != null) return usage();
        once = true;
    }
    const runtime_config = try config.load(allocator, config_path);
    defer config.deinit(allocator, runtime_config);
    const address = try std.net.Address.parseIp(runtime_config.bind_address, runtime_config.port);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();
    var runtime_dependencies = RuntimeDependencies{ .allocator = allocator, .runtime_config = runtime_config };
    const dependencies = runtime_dependencies.dependencies();
    std.debug.print("services: listening on {s}:{d}\n", .{ runtime_config.bind_address, server.listen_address.getPort() });
    if (once) return;
    while (true) {
        var connection = try server.accept();
        serve(&connection, dependencies);
    }
}

fn serve(connection: *std.net.Server.Connection, dependencies: health.Dependencies) void {
    defer connection.stream.close();
    var request: [max_http_request_bytes]u8 = undefined;
    const length = connection.stream.read(&request) catch return;
    if (length == 0) return;
    const response = health.response(requestTarget(request[0..length]), dependencies);
    var header: [128]u8 = undefined;
    const reason = switch (response.status) {
        200 => "OK",
        404 => "Not Found",
        503 => "Service Unavailable",
        else => "Internal Server Error",
    };
    const encoded = std.fmt.bufPrint(&header, "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ response.status, reason, response.body.len }) catch return;
    connection.stream.writeAll(encoded) catch return;
    connection.stream.writeAll(response.body) catch {};
}

fn requestTarget(request: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, request, "GET ")) return "";
    var end: usize = 4;
    while (end < request.len and request[end] != ' ') : (end += 1) {
        if (end - 4 >= 64) return "";
    }
    if (end == request.len or end == 4) return "";
    return request[4..end];
}

fn usage() error{InvalidArguments} {
    std.debug.print("usage: zig build run -- --config <path> [--once]\n", .{});
    return error.InvalidArguments;
}

test "request target accepts only bounded GET endpoints" {
    try std.testing.expectEqualStrings("/healthz", requestTarget("GET /healthz HTTP/1.1\r\n"));
    try std.testing.expectEqualStrings("", requestTarget("POST /healthz HTTP/1.1\r\n"));
    try std.testing.expectEqualStrings("", requestTarget("GET HTTP/1.1\r\n"));
}
