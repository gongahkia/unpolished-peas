const std = @import("std");
const service = @import("service_module.zig");

pub const max_http_route_parameters: usize = 8;
pub const HttpServiceRoutingError = std.mem.Allocator.Error || service.ServiceModuleError || error{ InvalidConfiguration, RouteCapacityExceeded, DuplicateRoute, RouteNotFound, ParameterCapacityExceeded, BodyTooLarge, MalformedPath };
pub const HttpRouteMethod = enum { get, head, post, put, patch, delete, options };
pub const HttpPathParameter = struct { name: []const u8, value: []const u8 };
pub const HttpRouteRequest = struct {
    method: HttpRouteMethod,
    path: []const u8,
    credentials: []const u8 = &.{},
    body: []const u8 = &.{},

    pub fn validate(self: HttpRouteRequest) HttpServiceRoutingError!void {
        try validatePath(self.path, false);
    }
};
pub const HttpServiceRouteConfig = struct {
    method: HttpRouteMethod,
    pattern: []const u8,
    module: service.ServiceModuleId,
    maximum_body_bytes: usize,

    pub fn validate(self: HttpServiceRouteConfig) HttpServiceRoutingError!void {
        if (self.maximum_body_bytes == 0) return error.InvalidConfiguration;
        try validatePath(self.pattern, true);
    }
};
pub const HttpServiceRouterConfig = struct {
    services: *service.ServiceRegistry,
    maximum_routes: usize,

    pub fn validate(self: HttpServiceRouterConfig) HttpServiceRoutingError!void {
        if (self.maximum_routes == 0) return error.InvalidConfiguration;
    }
};
pub const HttpRouteDispatch = struct { service: service.ServiceDispatch, parameters: []const HttpPathParameter };

const Entry = struct {
    config: HttpServiceRouteConfig,
    pattern: []u8,

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.pattern);
        self.* = undefined;
    }
};

const RouteScore = struct { literals: usize, segments: usize };

pub const HttpServiceRouter = struct {
    allocator: std.mem.Allocator,
    services: *service.ServiceRegistry,
    capacity: usize,
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator, config: HttpServiceRouterConfig) HttpServiceRoutingError!HttpServiceRouter {
        try config.validate();
        return .{ .allocator = allocator, .services = config.services, .capacity = config.maximum_routes };
    }

    pub fn deinit(self: *HttpServiceRouter) void {
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn register(self: *HttpServiceRouter, config: HttpServiceRouteConfig) HttpServiceRoutingError!void {
        try config.validate();
        if (self.entries.items.len == self.capacity) return error.RouteCapacityExceeded;
        for (self.entries.items) |entry| {
            if (entry.config.method == config.method and std.mem.eql(u8, entry.pattern, config.pattern)) return error.DuplicateRoute;
        }
        const pattern = try self.allocator.dupe(u8, config.pattern);
        errdefer self.allocator.free(pattern);
        try self.entries.append(self.allocator, .{ .config = config, .pattern = pattern });
    }

    pub fn dispatch(self: *HttpServiceRouter, request: HttpRouteRequest, parameters: []HttpPathParameter) HttpServiceRoutingError!HttpRouteDispatch {
        try request.validate();
        var selected: ?usize = null;
        var selected_score: RouteScore = undefined;
        for (self.entries.items, 0..) |entry, index| {
            if (entry.config.method != request.method) continue;
            const score = routeScore(entry.pattern, request.path) orelse continue;
            if (selected == null or score.literals > selected_score.literals or (score.literals == selected_score.literals and score.segments > selected_score.segments)) {
                selected = index;
                selected_score = score;
            }
        }
        const entry = &(self.entries.items[selected orelse return error.RouteNotFound]);
        if (request.body.len > entry.config.maximum_body_bytes) return error.BodyTooLarge;
        const matched = try captureParameters(entry.pattern, request.path, parameters);
        const dispatched = try self.services.dispatchModule(entry.config.module, .{ .route = request.path, .credentials = request.credentials, .payload = request.body });
        return .{ .service = dispatched, .parameters = matched };
    }
};

fn validatePath(path: []const u8, pattern: bool) HttpServiceRoutingError!void {
    if (path.len == 0 or path.len > service.max_service_route_prefix_bytes or path[0] != '/') return error.MalformedPath;
    if (std.mem.eql(u8, path, "/")) return;
    var segment_start: usize = 1;
    var parameter_count: usize = 0;
    var index: usize = 1;
    while (index <= path.len) : (index += 1) {
        if (index != path.len and path[index] != '/') {
            const byte = path[index];
            if (byte <= ' ' or byte == 0x7f or byte == '?' or byte == '#') return error.MalformedPath;
            continue;
        }
        const segment = path[segment_start..index];
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.MalformedPath;
        if (pattern and segment[0] == ':') {
            parameter_count += 1;
            if (parameter_count > max_http_route_parameters or segment.len == 1) return error.MalformedPath;
            for (segment[1..]) |byte| if (!(byte == '_' or byte == '-' or std.ascii.isAlphanumeric(byte))) return error.MalformedPath;
        } else if (std.mem.indexOfScalar(u8, segment, ':') != null) return error.MalformedPath;
        segment_start = index + 1;
    }
}

fn routeScore(pattern: []const u8, path: []const u8) ?RouteScore {
    if (std.mem.eql(u8, pattern, "/")) return if (std.mem.eql(u8, path, "/")) .{ .literals = 0, .segments = 0 } else null;
    var pattern_start: usize = 1;
    var path_start: usize = 1;
    var score = RouteScore{ .literals = 0, .segments = 0 };
    while (pattern_start < pattern.len and path_start < path.len) {
        const pattern_end = std.mem.indexOfScalarPos(u8, pattern, pattern_start, '/') orelse pattern.len;
        const path_end = std.mem.indexOfScalarPos(u8, path, path_start, '/') orelse path.len;
        const pattern_segment = pattern[pattern_start..pattern_end];
        const path_segment = path[path_start..path_end];
        if (pattern_segment[0] != ':' and !std.mem.eql(u8, pattern_segment, path_segment)) return null;
        if (pattern_segment[0] != ':') score.literals += 1;
        score.segments += 1;
        pattern_start = pattern_end + 1;
        path_start = path_end + 1;
    }
    return if (pattern_start > pattern.len and path_start > path.len) score else null;
}

fn captureParameters(pattern: []const u8, path: []const u8, output: []HttpPathParameter) HttpServiceRoutingError![]HttpPathParameter {
    var pattern_start: usize = 1;
    var path_start: usize = 1;
    var count: usize = 0;
    while (pattern_start < pattern.len) {
        const pattern_end = std.mem.indexOfScalarPos(u8, pattern, pattern_start, '/') orelse pattern.len;
        const path_end = std.mem.indexOfScalarPos(u8, path, path_start, '/') orelse path.len;
        const pattern_segment = pattern[pattern_start..pattern_end];
        if (pattern_segment[0] == ':') {
            if (count == output.len) return error.ParameterCapacityExceeded;
            output[count] = .{ .name = pattern_segment[1..], .value = path[path_start..path_end] };
            count += 1;
        }
        pattern_start = pattern_end + 1;
        path_start = path_end + 1;
    }
    return output[0..count];
}

test "HTTP service routers choose deterministic method routes with bounded path parameters" {
    const Fixture = struct {
        calls: usize = 0,

        fn route(context: ?*anyopaque, _: service.ServiceRequest) service.ServiceModuleError!service.ServiceRouteResult {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            return .handled;
        }
    };
    var dynamic = Fixture{};
    var exact = Fixture{};
    var services = try service.ServiceRegistry.init(std.testing.allocator, .{ .maximum_modules = 2 });
    defer services.deinit();
    const dynamic_module = try services.register(.{ .config = .{ .name = "dynamic", .route_prefix = "/users", .maximum_state_bytes = 1 }, .context = &dynamic, .hooks = .{ .route = Fixture.route } });
    const exact_module = try services.register(.{ .config = .{ .name = "exact", .route_prefix = "/me", .maximum_state_bytes = 1 }, .context = &exact, .hooks = .{ .route = Fixture.route } });
    try services.start();
    var router = try HttpServiceRouter.init(std.testing.allocator, .{ .services = &services, .maximum_routes = 2 });
    defer router.deinit();
    try router.register(.{ .method = .get, .pattern = "/users/:id", .module = dynamic_module, .maximum_body_bytes = 8 });
    try router.register(.{ .method = .get, .pattern = "/users/me", .module = exact_module, .maximum_body_bytes = 8 });
    var parameters: [max_http_route_parameters]HttpPathParameter = undefined;
    const exact_dispatch = try router.dispatch(.{ .method = .get, .path = "/users/me" }, parameters[0..]);
    try std.testing.expectEqual(exact_module, exact_dispatch.service.module);
    try std.testing.expectEqual(@as(usize, 0), exact_dispatch.parameters.len);
    const parameterized = try router.dispatch(.{ .method = .get, .path = "/users/42" }, parameters[0..]);
    try std.testing.expectEqual(dynamic_module, parameterized.service.module);
    try std.testing.expectEqualStrings("id", parameterized.parameters[0].name);
    try std.testing.expectEqualStrings("42", parameterized.parameters[0].value);
    try std.testing.expectEqual(@as(usize, 1), dynamic.calls);
    try std.testing.expectEqual(@as(usize, 1), exact.calls);
    try std.testing.expectError(error.MalformedPath, router.dispatch(.{ .method = .get, .path = "/users//bad" }, parameters[0..]));
    try std.testing.expectError(error.BodyTooLarge, router.dispatch(.{ .method = .get, .path = "/users/42", .body = "overflowing" }, parameters[0..]));
}
