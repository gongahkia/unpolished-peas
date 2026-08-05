const std = @import("std");
const core = @import("minna-san-core");
const protocol = @import("minna-san-protocol");
const service = @import("service_module.zig");
const resource = @import("resource_handle.zig");
const tls_server = @import("tls_server_listener.zig");

pub const HttpServerLifecycleError = std.mem.Allocator.Error || protocol.HttpParserError || service.ServiceModuleError || tls_server.TlsServerListenerError || error{ InvalidConfiguration, OutputTooSmall, InvalidState, RequestBodyTooLarge };
pub const HttpServerConnectionState = enum { ready, closing, closed };
pub const HttpServerResponse = struct { sequence: u64, status: u16, keep_alive: bool, dispatch: ?service.ServiceDispatch = null };
pub const HttpServerEvent = union(enum) { parsing: protocol.HttpParserEvent, response: HttpServerResponse };
pub const HttpServerConfig = struct {
    services: *service.ServiceRegistry,
    parser: protocol.HttpParserConfig,
    tls_listener: ?*tls_server.TlsServerListener = null,
    tls_session: ?*resource.ResourceHandle = null,

    pub fn validate(self: HttpServerConfig) HttpServerLifecycleError!void {
        if (self.parser.kind != .request or (self.tls_listener == null) != (self.tls_session == null)) return error.InvalidConfiguration;
        try self.parser.validate();
    }
};

pub const HttpServerConnection = struct {
    allocator: std.mem.Allocator,
    config: HttpServerConfig,
    parser: protocol.HttpParser,
    target: std.ArrayListUnmanaged(u8) = .empty,
    credentials: std.ArrayListUnmanaged(u8) = .empty,
    body: std.ArrayListUnmanaged(u8) = .empty,
    keep_alive: bool = true,
    sequence: u64 = 0,
    state: HttpServerConnectionState = .ready,

    pub fn init(allocator: std.mem.Allocator, config: HttpServerConfig) HttpServerLifecycleError!HttpServerConnection {
        try config.validate();
        return .{ .allocator = allocator, .config = config, .parser = try protocol.HttpParser.init(config.parser) };
    }

    pub fn deinit(self: *HttpServerConnection) void {
        self.target.deinit(self.allocator);
        self.credentials.deinit(self.allocator);
        self.body.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn feed(self: *HttpServerConnection, input: []const u8) HttpServerLifecycleError!struct { consumed: usize, event: ?HttpServerEvent } {
        if (self.state != .ready) return error.InvalidState;
        const parsed = try self.parser.feed(input);
        const event = parsed.event orelse return .{ .consumed = parsed.consumed, .event = null };
        switch (event) {
            .request_line => |request| {
                self.target.clearRetainingCapacity();
                try self.target.appendSlice(self.allocator, request.target);
                self.credentials.clearRetainingCapacity();
                self.body.clearRetainingCapacity();
                self.keep_alive = true;
            },
            .header => |header| if (std.ascii.eqlIgnoreCase(header.name, "connection")) {
                self.keep_alive = !std.ascii.eqlIgnoreCase(header.value, "close");
            } else if (std.ascii.eqlIgnoreCase(header.name, "authorization")) {
                self.credentials.clearRetainingCapacity();
                try self.credentials.appendSlice(self.allocator, header.value);
            },
            .body => |bytes| {
                if (bytes.len > self.config.parser.maximum_body_bytes - self.body.items.len) return error.RequestBodyTooLarge;
                try self.body.appendSlice(self.allocator, bytes);
            },
            .headers_complete => |framing| switch (framing) {
                .none => return .{ .consumed = parsed.consumed, .event = .{ .response = try self.dispatch() } },
                .content_length => |length| if (length == 0) return .{ .consumed = parsed.consumed, .event = .{ .response = try self.dispatch() } },
                .chunked => {},
            },
            .complete => return .{ .consumed = parsed.consumed, .event = .{ .response = try self.dispatch() } },
            else => {},
        }
        return .{ .consumed = parsed.consumed, .event = .{ .parsing = event } };
    }

    pub fn feedTls(self: *HttpServerConnection, now_ns: core.TimeNs, input: []const u8) HttpServerLifecycleError!struct { consumed: usize, event: ?HttpServerEvent } {
        const tls_listener = self.config.tls_listener orelse return error.InvalidConfiguration;
        const tls_session = self.config.tls_session orelse return error.InvalidConfiguration;
        const connection = try tls_listener.poll(tls_session, now_ns);
        if (connection.state != .ready) return error.InvalidState;
        return self.feed(input);
    }

    pub fn encodeResponse(response: HttpServerResponse, output: []u8) HttpServerLifecycleError![]u8 {
        const reason = switch (response.status) {
            200 => "OK",
            401 => "Unauthorized",
            404 => "Not Found",
            else => "Internal Server Error",
        };
        const connection = if (response.keep_alive) "keep-alive" else "close";
        return std.fmt.bufPrint(output, "HTTP/1.1 {d} {s}\r\nContent-Length: 0\r\nConnection: {s}\r\n\r\n", .{ response.status, reason, connection }) catch error.OutputTooSmall;
    }

    fn dispatch(self: *HttpServerConnection) HttpServerLifecycleError!HttpServerResponse {
        const result = self.config.services.dispatch(.{ .route = self.target.items, .credentials = self.credentials.items, .payload = self.body.items }) catch |err| switch (err) {
            error.RouteNotFound => return self.finish(.{ .sequence = self.sequence, .status = 404, .keep_alive = self.keep_alive }),
            error.CredentialRejected => return self.finish(.{ .sequence = self.sequence, .status = 401, .keep_alive = self.keep_alive }),
            else => return self.finish(.{ .sequence = self.sequence, .status = 500, .keep_alive = false }),
        };
        return self.finish(.{ .sequence = self.sequence, .status = if (result.result == .handled) 200 else 404, .keep_alive = self.keep_alive, .dispatch = result });
    }

    fn finish(self: *HttpServerConnection, response: HttpServerResponse) HttpServerResponse {
        self.sequence +%= 1;
        if (response.keep_alive) self.parser.reset() else self.state = .closing;
        return response;
    }
};

test "HTTP server handlers return two keep-alive responses over one bounded connection lifecycle" {
    const Fixture = struct {
        calls: usize = 0,
        fn route(context: ?*anyopaque, request: service.ServiceRequest) service.ServiceModuleError!service.ServiceRouteResult {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            if (!std.mem.eql(u8, "/public", request.route)) return error.CallbackFailed;
            return .handled;
        }
    };
    var fixture = Fixture{};
    var services = try service.ServiceRegistry.init(std.testing.allocator, .{ .maximum_modules = 1 });
    defer services.deinit();
    _ = try services.register(.{ .config = .{ .name = "public", .route_prefix = "/public", .maximum_state_bytes = 1 }, .context = &fixture, .hooks = .{ .route = Fixture.route } });
    try services.start();
    var connection = try HttpServerConnection.init(std.testing.allocator, .{ .services = &services, .parser = .{ .kind = .request, .maximum_body_bytes = 16 } });
    defer connection.deinit();
    const wire = "GET /public HTTP/1.1\r\nHost: example.test\r\n\r\nGET /public HTTP/1.1\r\nHost: example.test\r\n\r\n";
    var offset: usize = 0;
    var responses: [2]HttpServerResponse = undefined;
    var count: usize = 0;
    while (offset < wire.len and count < responses.len) {
        const result = try connection.feed(wire[offset..]);
        offset += result.consumed;
        if (result.event) |event| if (event == .response) {
            responses[count] = event.response;
            count += 1;
        };
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    try std.testing.expect(responses[0].keep_alive and responses[1].keep_alive);
    var encoded: [96]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, try HttpServerConnection.encodeResponse(responses[0], encoded[0..]), "HTTP/1.1 200 OK\r\n"));
}
