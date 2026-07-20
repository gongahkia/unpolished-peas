const std = @import("std");
const core = @import("minna-san-core");

pub const max_service_module_name_bytes: usize = 64;
pub const max_service_route_prefix_bytes: usize = 128;
pub const ServiceModuleId = usize;
pub const ServiceModuleState = enum(u8) { registered, active, stopped, failed };
pub const ServiceCredentialDecision = enum(u8) { allow, deny };
pub const ServiceRouteResult = enum(u8) { handled, declined };
pub const ServiceModuleError = std.mem.Allocator.Error || error{ InvalidConfiguration, ModuleCapacityExceeded, DuplicateModuleName, DuplicateRoutePrefix, InvalidState, RouteNotFound, CredentialRejected, CallbackFailed };

pub const ServiceModuleConfig = struct {
    name: []const u8,
    route_prefix: []const u8,
    maximum_state_bytes: usize,

    pub fn validate(self: ServiceModuleConfig) ServiceModuleError!void {
        if (self.name.len == 0 or self.name.len > max_service_module_name_bytes or self.route_prefix.len == 0 or self.route_prefix.len > max_service_route_prefix_bytes or self.maximum_state_bytes == 0) return error.InvalidConfiguration;
        for (self.name) |byte| if (!(byte == '-' or byte == '_' or std.ascii.isAlphanumeric(byte))) return error.InvalidConfiguration;
        if (self.route_prefix[0] != '/' or (self.route_prefix.len > 1 and self.route_prefix[self.route_prefix.len - 1] == '/')) return error.InvalidConfiguration;
    }
};

pub const ServiceRequest = struct {
    route: []const u8,
    credentials: []const u8,
    payload: []const u8,

    pub fn validate(self: ServiceRequest) ServiceModuleError!void {
        if (self.route.len == 0 or self.route.len > max_service_route_prefix_bytes or self.route[0] != '/') return error.InvalidConfiguration;
    }
};

pub const ServiceInitializeFn = *const fn (context: ?*anyopaque) ServiceModuleError!void;
pub const ServiceAuthorizeFn = *const fn (context: ?*anyopaque, request: ServiceRequest) ServiceModuleError!ServiceCredentialDecision;
pub const ServiceRouteFn = *const fn (context: ?*anyopaque, request: ServiceRequest) ServiceModuleError!ServiceRouteResult;
pub const ServiceTeardownFn = *const fn (context: ?*anyopaque) void;

pub const ServiceModuleHooks = struct {
    initialize: ?ServiceInitializeFn = null,
    authorize: ?ServiceAuthorizeFn = null,
    route: ServiceRouteFn,
    teardown: ?ServiceTeardownFn = null,
};

pub const ServiceModule = struct {
    config: ServiceModuleConfig,
    context: ?*anyopaque,
    hooks: ServiceModuleHooks,
};

pub const ServiceRegistryConfig = struct {
    maximum_modules: usize,

    pub fn validate(self: ServiceRegistryConfig) ServiceModuleError!void {
        if (self.maximum_modules > core.max_service_capacity) return error.InvalidConfiguration;
    }
};

pub const ServiceDispatch = struct {
    module: ServiceModuleId,
    module_name: []const u8,
    result: ServiceRouteResult,
};

const Entry = struct {
    name: []u8,
    route_prefix: []u8,
    maximum_state_bytes: usize,
    context: ?*anyopaque,
    hooks: ServiceModuleHooks,
    state: ServiceModuleState = .registered,

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        if (self.state == .active) {
            if (self.hooks.teardown) |teardown| teardown(self.context);
            self.state = .stopped;
        }
        allocator.free(self.name);
        allocator.free(self.route_prefix);
        self.* = undefined;
    }
};

pub const ServiceRegistry = struct {
    allocator: std.mem.Allocator,
    config: ServiceRegistryConfig,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    started: bool = false,

    pub fn init(allocator: std.mem.Allocator, config: ServiceRegistryConfig) ServiceModuleError!ServiceRegistry {
        try config.validate();
        return .{ .allocator = allocator, .config = config };
    }

    pub fn deinit(self: *ServiceRegistry) void {
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn module_count(self: ServiceRegistry) usize {
        return self.entries.items.len;
    }

    pub fn register(self: *ServiceRegistry, module: ServiceModule) ServiceModuleError!ServiceModuleId {
        if (self.started) return error.InvalidState;
        try module.config.validate();
        if (self.entries.items.len == self.config.maximum_modules) return error.ModuleCapacityExceeded;
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.name, module.config.name)) return error.DuplicateModuleName;
            if (std.mem.eql(u8, entry.route_prefix, module.config.route_prefix)) return error.DuplicateRoutePrefix;
        }
        const name = try self.allocator.dupe(u8, module.config.name);
        errdefer self.allocator.free(name);
        const route_prefix = try self.allocator.dupe(u8, module.config.route_prefix);
        errdefer self.allocator.free(route_prefix);
        try self.entries.append(self.allocator, .{ .name = name, .route_prefix = route_prefix, .maximum_state_bytes = module.config.maximum_state_bytes, .context = module.context, .hooks = module.hooks });
        return self.entries.items.len - 1;
    }

    pub fn start(self: *ServiceRegistry) ServiceModuleError!void {
        if (self.started) return error.InvalidState;
        var initialized: usize = 0;
        for (self.entries.items) |*entry| {
            if (entry.hooks.initialize) |initialize| initialize(entry.context) catch {
                entry.state = .failed;
                while (initialized > 0) {
                    initialized -= 1;
                    stop_entry(&self.entries.items[initialized]);
                }
                return error.CallbackFailed;
            };
            entry.state = .active;
            initialized += 1;
        }
        self.started = true;
    }

    pub fn stop(self: *ServiceRegistry) void {
        for (self.entries.items) |*entry| stop_entry(entry);
        self.started = false;
    }

    pub fn dispatch(self: *ServiceRegistry, request: ServiceRequest) ServiceModuleError!ServiceDispatch {
        if (!self.started) return error.InvalidState;
        try request.validate();
        const module = self.find_route(request.route) orelse return error.RouteNotFound;
        var entry = &self.entries.items[module];
        if (entry.hooks.authorize) |authorize| {
            const decision = authorize(entry.context, request) catch return error.CallbackFailed;
            if (decision == .deny) return error.CredentialRejected;
        }
        const result = entry.hooks.route(entry.context, request) catch return error.CallbackFailed;
        return .{ .module = module, .module_name = entry.name, .result = result };
    }

    fn stop_entry(entry: *Entry) void {
        if (entry.state != .active) return;
        if (entry.hooks.teardown) |teardown| teardown(entry.context);
        entry.state = .stopped;
    }

    fn find_route(self: *const ServiceRegistry, route: []const u8) ?ServiceModuleId {
        var best: ?ServiceModuleId = null;
        for (self.entries.items, 0..) |entry, index| {
            if (entry.state != .active or !route_matches(entry.route_prefix, route)) continue;
            if (best == null or entry.route_prefix.len > self.entries.items[best.?].route_prefix.len) best = index;
        }
        return best;
    }
};

fn route_matches(prefix: []const u8, route: []const u8) bool {
    if (std.mem.eql(u8, prefix, "/")) return true;
    return std.mem.startsWith(u8, route, prefix) and (route.len == prefix.len or route[prefix.len] == '/');
}

test "service modules compose with isolated state routing and credential callbacks" {
    const Fixture = struct {
        expected_credentials: []const u8,
        starts: usize = 0,
        stops: usize = 0,
        routes: usize = 0,

        fn initialize(context: ?*anyopaque) ServiceModuleError!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.starts += 1;
        }

        fn authorize(context: ?*anyopaque, request: ServiceRequest) ServiceModuleError!ServiceCredentialDecision {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            return if (std.mem.eql(u8, self.expected_credentials, request.credentials)) .allow else .deny;
        }

        fn route(context: ?*anyopaque, _: ServiceRequest) ServiceModuleError!ServiceRouteResult {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.routes += 1;
            return .handled;
        }

        fn teardown(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.stops += 1;
        }

        fn module(self: *@This(), name: []const u8, route_prefix: []const u8) ServiceModule {
            return .{ .config = .{ .name = name, .route_prefix = route_prefix, .maximum_state_bytes = 32 }, .context = self, .hooks = .{ .initialize = initialize, .authorize = authorize, .route = route, .teardown = teardown } };
        }
    };
    var registry = try ServiceRegistry.init(std.testing.allocator, .{ .maximum_modules = 2 });
    defer registry.deinit();
    var game = Fixture{ .expected_credentials = "game" };
    var status = Fixture{ .expected_credentials = "status" };
    _ = try registry.register(game.module("game", "/game"));
    _ = try registry.register(status.module("status", "/status"));
    try registry.start();
    const game_dispatch = try registry.dispatch(.{ .route = "/game/session", .credentials = "game", .payload = "input" });
    try std.testing.expectEqual(@as(usize, 0), game_dispatch.module);
    try std.testing.expectEqual(ServiceRouteResult.handled, game_dispatch.result);
    const status_dispatch = try registry.dispatch(.{ .route = "/status", .credentials = "status", .payload = "" });
    try std.testing.expectEqual(@as(usize, 1), status_dispatch.module);
    try std.testing.expectEqual(@as(usize, 1), game.routes);
    try std.testing.expectEqual(@as(usize, 1), status.routes);
    try std.testing.expectError(error.CredentialRejected, registry.dispatch(.{ .route = "/game", .credentials = "status", .payload = "" }));
    try std.testing.expectEqual(@as(usize, 1), game.routes);
    registry.stop();
    try std.testing.expectEqual(@as(usize, 1), game.stops);
    try std.testing.expectEqual(@as(usize, 1), status.stops);
}

test "service modules use bounded deterministic routes and reject invalid lifecycle" {
    const no_op = struct {
        fn route(_: ?*anyopaque, _: ServiceRequest) ServiceModuleError!ServiceRouteResult {
            return .handled;
        }
    }.route;
    var registry = try ServiceRegistry.init(std.testing.allocator, .{ .maximum_modules = 2 });
    defer registry.deinit();
    try std.testing.expectError(error.InvalidState, registry.dispatch(.{ .route = "/", .credentials = "", .payload = "" }));
    _ = try registry.register(.{ .config = .{ .name = "root", .route_prefix = "/", .maximum_state_bytes = 1 }, .context = null, .hooks = .{ .route = no_op } });
    _ = try registry.register(.{ .config = .{ .name = "game", .route_prefix = "/game", .maximum_state_bytes = 1 }, .context = null, .hooks = .{ .route = no_op } });
    try std.testing.expectError(error.ModuleCapacityExceeded, registry.register(.{ .config = .{ .name = "extra", .route_prefix = "/extra", .maximum_state_bytes = 1 }, .context = null, .hooks = .{ .route = no_op } }));
    try registry.start();
    try std.testing.expectEqual(@as(usize, 1), (try registry.dispatch(.{ .route = "/game/one", .credentials = "", .payload = "" })).module);
    try std.testing.expectEqual(@as(usize, 0), (try registry.dispatch(.{ .route = "/games", .credentials = "", .payload = "" })).module);
    try std.testing.expectError(error.InvalidState, registry.register(.{ .config = .{ .name = "late", .route_prefix = "/late", .maximum_state_bytes = 1 }, .context = null, .hooks = .{ .route = no_op } }));
}
