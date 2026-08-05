const std = @import("std");

pub const DependencyStatus = enum { ok, unavailable };
pub const Readiness = struct {
    database: DependencyStatus,
    relay: DependencyStatus,

    pub fn ready(self: Readiness) bool {
        return self.database == .ok and self.relay == .ok;
    }
};
pub const Dependencies = struct {
    context: *anyopaque,
    check_database_fn: *const fn (context: *anyopaque) anyerror!void,
    check_relay_fn: *const fn (context: *anyopaque) anyerror!void,

    pub fn checkDatabase(self: Dependencies) !void {
        try self.check_database_fn(self.context);
    }

    pub fn checkRelay(self: Dependencies) !void {
        try self.check_relay_fn(self.context);
    }
};
pub const HttpResponse = struct { status: u16, body: []const u8 };

pub fn readiness(dependencies: Dependencies) Readiness {
    var result = Readiness{ .database = .ok, .relay = .ok };
    dependencies.checkDatabase() catch {
        result.database = .unavailable;
    };
    dependencies.checkRelay() catch {
        result.relay = .unavailable;
    };
    return result;
}

pub fn response(path: []const u8, dependencies: Dependencies) HttpResponse {
    if (std.mem.eql(u8, path, "/healthz")) return .{ .status = 200, .body = "{\"status\":\"ok\"}\n" };
    if (!std.mem.eql(u8, path, "/readyz")) return .{ .status = 404, .body = "{\"status\":\"not_found\"}\n" };
    const result = readiness(dependencies);
    return switch (result.database) {
        .ok => switch (result.relay) {
            .ok => .{ .status = 200, .body = "{\"database\":\"ok\",\"relay\":\"ok\"}\n" },
            .unavailable => .{ .status = 503, .body = "{\"database\":\"ok\",\"relay\":\"unavailable\"}\n" },
        },
        .unavailable => switch (result.relay) {
            .ok => .{ .status = 503, .body = "{\"database\":\"unavailable\",\"relay\":\"ok\"}\n" },
            .unavailable => .{ .status = 503, .body = "{\"database\":\"unavailable\",\"relay\":\"unavailable\"}\n" },
        },
    };
}

const FakeDependencies = struct {
    database_calls: u8 = 0,
    relay_calls: u8 = 0,
    database_error: bool = false,
    relay_error: bool = false,

    fn dependencies(self: *FakeDependencies) Dependencies {
        return .{ .context = self, .check_database_fn = database, .check_relay_fn = relay };
    }

    fn database(context: *anyopaque) !void {
        const self: *FakeDependencies = @ptrCast(@alignCast(context));
        self.database_calls += 1;
        if (self.database_error) return error.DatabaseUnavailable;
    }

    fn relay(context: *anyopaque) !void {
        const self: *FakeDependencies = @ptrCast(@alignCast(context));
        self.relay_calls += 1;
        if (self.relay_error) return error.RelayUnavailable;
    }
};

test "readiness exercises database and relay dependencies" {
    var fake = FakeDependencies{};
    const ready = readiness(fake.dependencies());
    try std.testing.expect(ready.ready());
    try std.testing.expectEqual(@as(u8, 1), fake.database_calls);
    try std.testing.expectEqual(@as(u8, 1), fake.relay_calls);
    fake.database_error = true;
    const unavailable = readiness(fake.dependencies());
    try std.testing.expect(!unavailable.ready());
    try std.testing.expectEqual(DependencyStatus.unavailable, unavailable.database);
    try std.testing.expectEqual(DependencyStatus.ok, unavailable.relay);
    try std.testing.expectEqual(@as(u8, 2), fake.database_calls);
    try std.testing.expectEqual(@as(u8, 2), fake.relay_calls);
}

test "health endpoints expose liveness readiness and not found states" {
    var fake = FakeDependencies{};
    const dependencies = fake.dependencies();
    const liveness = response("/healthz", dependencies);
    try std.testing.expectEqual(@as(u16, 200), liveness.status);
    try std.testing.expectEqual(@as(u8, 0), fake.database_calls);
    const ready = response("/readyz", dependencies);
    try std.testing.expectEqual(@as(u16, 200), ready.status);
    fake.relay_error = true;
    try std.testing.expectEqual(@as(u16, 503), response("/readyz", dependencies).status);
    try std.testing.expectEqual(@as(u16, 404), response("/unknown", dependencies).status);
}
