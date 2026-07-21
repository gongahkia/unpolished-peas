const std = @import("std");
const routing = @import("http_service_routing.zig");

pub const max_http_middleware: usize = 32;
pub const max_http_middleware_local_bytes: usize = 64 * 1024;
pub const HttpMiddlewarePipelineError = std.mem.Allocator.Error || routing.HttpServiceRoutingError || error{ InvalidConfiguration, MiddlewareCapacityExceeded, InvalidStatus };
pub const HttpMiddlewareRequest = struct {
    method: routing.HttpRouteMethod,
    path: []const u8,
    credentials: []const u8 = &.{},
    body: []const u8 = &.{},

    pub fn validate(self: HttpMiddlewareRequest) HttpMiddlewarePipelineError!void {
        try (routing.HttpRouteRequest{ .method = self.method, .path = self.path, .credentials = self.credentials, .body = self.body }).validate();
    }
};
pub const HttpMiddlewareContext = struct { request: HttpMiddlewareRequest, local: []u8 };
pub const HttpMiddlewareAction = union(enum) { next: void, respond: u16 };
pub const HttpMiddlewareResponse = struct { status: u16 };
pub const HttpMiddlewareResult = struct { response: HttpMiddlewareResponse, middleware_executed: usize, handler_executed: bool };
pub const HttpMiddlewareFn = *const fn (?*anyopaque, HttpMiddlewareContext) anyerror!HttpMiddlewareAction;
pub const HttpMiddlewareHandlerFn = *const fn (?*anyopaque, HttpMiddlewareContext) anyerror!HttpMiddlewareResponse;
pub const HttpMiddleware = struct { context: ?*anyopaque = null, run: HttpMiddlewareFn };
pub const HttpMiddlewareHandler = struct { context: ?*anyopaque = null, run: HttpMiddlewareHandlerFn };
pub const HttpMiddlewarePipelineConfig = struct {
    maximum_middleware: usize,
    maximum_local_bytes: usize,
    handler: HttpMiddlewareHandler,
    internal_error_status: u16 = 500,

    pub fn validate(self: HttpMiddlewarePipelineConfig) HttpMiddlewarePipelineError!void {
        if (self.maximum_middleware == 0 or self.maximum_middleware > max_http_middleware or self.maximum_local_bytes == 0 or self.maximum_local_bytes > max_http_middleware_local_bytes) return error.InvalidConfiguration;
        try validateStatus(self.internal_error_status);
    }
};

pub const HttpMiddlewarePipeline = struct {
    allocator: std.mem.Allocator,
    handler: HttpMiddlewareHandler,
    internal_error_status: u16,
    local: []u8,
    capacity: usize,
    middleware: std.ArrayListUnmanaged(HttpMiddleware) = .empty,

    pub fn init(allocator: std.mem.Allocator, config: HttpMiddlewarePipelineConfig) HttpMiddlewarePipelineError!HttpMiddlewarePipeline {
        try config.validate();
        return .{ .allocator = allocator, .handler = config.handler, .internal_error_status = config.internal_error_status, .local = try allocator.alloc(u8, config.maximum_local_bytes), .capacity = config.maximum_middleware };
    }

    pub fn deinit(self: *HttpMiddlewarePipeline) void {
        self.middleware.deinit(self.allocator);
        self.allocator.free(self.local);
        self.* = undefined;
    }

    pub fn append(self: *HttpMiddlewarePipeline, middleware: HttpMiddleware) HttpMiddlewarePipelineError!void {
        if (self.middleware.items.len == self.capacity) return error.MiddlewareCapacityExceeded;
        try self.middleware.append(self.allocator, middleware);
    }

    pub fn dispatch(self: *HttpMiddlewarePipeline, request: HttpMiddlewareRequest) HttpMiddlewarePipelineError!HttpMiddlewareResult {
        try request.validate();
        @memset(self.local, 0);
        const context = HttpMiddlewareContext{ .request = request, .local = self.local };
        var executed: usize = 0;
        for (self.middleware.items) |middleware| {
            executed += 1;
            const action = middleware.run(middleware.context, context) catch return .{ .response = .{ .status = self.internal_error_status }, .middleware_executed = executed, .handler_executed = false };
            switch (action) {
                .next => {},
                .respond => |status| {
                    try validateStatus(status);
                    return .{ .response = .{ .status = status }, .middleware_executed = executed, .handler_executed = false };
                },
            }
        }
        const response = self.handler.run(self.handler.context, context) catch return .{ .response = .{ .status = self.internal_error_status }, .middleware_executed = executed, .handler_executed = true };
        try validateStatus(response.status);
        return .{ .response = response, .middleware_executed = executed, .handler_executed = true };
    }
};

fn validateStatus(status: u16) HttpMiddlewarePipelineError!void {
    if (status < 100 or status > 599) return error.InvalidStatus;
}

test "rejecting HTTP middleware prevents handler execution with bounded request-local state" {
    const Fixture = struct {
        handler_calls: usize = 0,

        fn trace(_: ?*anyopaque, context: HttpMiddlewareContext) anyerror!HttpMiddlewareAction {
            context.local[0] = 1;
            return .next;
        }

        fn reject(_: ?*anyopaque, context: HttpMiddlewareContext) anyerror!HttpMiddlewareAction {
            try std.testing.expectEqual(@as(u8, 1), context.local[0]);
            return .{ .respond = 429 };
        }

        fn handler(context: ?*anyopaque, _: HttpMiddlewareContext) anyerror!HttpMiddlewareResponse {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.handler_calls += 1;
            return .{ .status = 200 };
        }
    };
    var fixture = Fixture{};
    var pipeline = try HttpMiddlewarePipeline.init(std.testing.allocator, .{ .maximum_middleware = 2, .maximum_local_bytes = 8, .handler = .{ .context = &fixture, .run = Fixture.handler } });
    defer pipeline.deinit();
    try pipeline.append(.{ .run = Fixture.trace });
    try pipeline.append(.{ .run = Fixture.reject });
    const result = try pipeline.dispatch(.{ .method = .get, .path = "/public" });
    try std.testing.expectEqual(@as(u16, 429), result.response.status);
    try std.testing.expectEqual(@as(usize, 2), result.middleware_executed);
    try std.testing.expect(!result.handler_executed);
    try std.testing.expectEqual(@as(usize, 0), fixture.handler_calls);
}
