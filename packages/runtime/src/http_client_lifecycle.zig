const std = @import("std");
const protocol = @import("minna-san-protocol");
const tls_client = @import("tls_client_route.zig");

pub const max_http_client_request_bytes: usize = protocol.max_http_header_bytes + protocol.max_http_body_bytes;
pub const HttpClientLifecycleError = std.mem.Allocator.Error || protocol.HttpParserError || tls_client.TlsClientRouteError || error{ InvalidConfiguration, InvalidState, InvalidRequest, RequestTooLarge, ResponseBodyTooLarge };
pub const HttpClientState = enum { idle, awaiting_response, cancelled, closed };
pub const HttpRedirectPolicy = enum { disabled };
pub const HttpClientHeader = struct { name: []const u8, value: []const u8 };
pub const HttpClientRequest = struct {
    method: []const u8,
    target: []const u8,
    authority: []const u8,
    headers: []const HttpClientHeader = &.{},
    body: []const u8 = &.{},
    close_after_response: bool = false,

    pub fn validate(self: HttpClientRequest) HttpClientLifecycleError!void {
        if (self.method.len == 0 or self.target.len == 0 or self.target[0] != '/' or self.authority.len == 0 or !validValue(self.authority)) return error.InvalidRequest;
        for (self.method) |byte| if (!isToken(byte)) return error.InvalidRequest;
        for (self.target) |byte| if (byte <= ' ' or byte == 0x7f) return error.InvalidRequest;
        for (self.headers) |header| {
            if (header.name.len == 0 or !validValue(header.value) or forbiddenRequestHeader(header.name)) return error.InvalidRequest;
            for (header.name) |byte| if (!isToken(byte)) return error.InvalidRequest;
        }
    }
};
pub const HttpClientResponse = struct {
    sequence: u64,
    status: u16,
    headers: []const HttpClientHeader,
    body: []const u8,
    keep_alive: bool,
    redirect_not_followed: bool,
};
pub const HttpClientEvent = union(enum) { parsing: protocol.HttpParserEvent, response: HttpClientResponse };
pub const HttpClientConfig = struct {
    parser: protocol.HttpParserConfig = .{ .kind = .response },
    maximum_request_bytes: usize = max_http_client_request_bytes,
    redirects: HttpRedirectPolicy = .disabled,
    tls_route: ?*tls_client.TlsClientRoute = null,

    pub fn validate(self: HttpClientConfig) HttpClientLifecycleError!void {
        if (self.parser.kind != .response or self.maximum_request_bytes == 0 or self.maximum_request_bytes > max_http_client_request_bytes) return error.InvalidConfiguration;
        try self.parser.validate();
    }
};

pub const HttpClientConnection = struct {
    allocator: std.mem.Allocator,
    config: HttpClientConfig,
    parser: protocol.HttpParser,
    outbound: std.ArrayListUnmanaged(u8) = .empty,
    headers: std.ArrayListUnmanaged(HttpClientHeader) = .empty,
    body: std.ArrayListUnmanaged(u8) = .empty,
    status: ?u16 = null,
    keep_alive: bool = true,
    next_sequence: u64 = 0,
    state: HttpClientState = .idle,

    pub fn init(allocator: std.mem.Allocator, config: HttpClientConfig) HttpClientLifecycleError!HttpClientConnection {
        try config.validate();
        return .{ .allocator = allocator, .config = config, .parser = try protocol.HttpParser.init(config.parser) };
    }

    pub fn deinit(self: *HttpClientConnection) void {
        self.close();
        self.clearResponse();
        self.headers.deinit(self.allocator);
        self.body.deinit(self.allocator);
        self.outbound.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn begin(self: *HttpClientConnection, request: HttpClientRequest) HttpClientLifecycleError![]const u8 {
        if (self.state != .idle) return error.InvalidState;
        try request.validate();
        const generated_headers: usize = if (request.body.len == 0) 2 else 3;
        if (request.body.len > self.config.parser.maximum_body_bytes or request.headers.len > self.config.parser.maximum_headers or request.headers.len + generated_headers > self.config.parser.maximum_headers) return error.RequestTooLarge;
        self.outbound.clearRetainingCapacity();
        self.append(request.method) catch |err| {
            self.outbound.clearRetainingCapacity();
            return err;
        };
        self.append(" ") catch |err| return self.clearOutbound(err);
        self.append(request.target) catch |err| return self.clearOutbound(err);
        self.append(" HTTP/1.1\r\nHost: ") catch |err| return self.clearOutbound(err);
        self.append(request.authority) catch |err| return self.clearOutbound(err);
        self.append("\r\n") catch |err| return self.clearOutbound(err);
        for (request.headers) |header| {
            self.append(header.name) catch |err| return self.clearOutbound(err);
            self.append(": ") catch |err| return self.clearOutbound(err);
            self.append(header.value) catch |err| return self.clearOutbound(err);
            self.append("\r\n") catch |err| return self.clearOutbound(err);
        }
        if (request.body.len != 0) {
            var length: [20]u8 = undefined;
            const decimal = std.fmt.bufPrint(&length, "{d}", .{request.body.len}) catch unreachable;
            self.append("Content-Length: ") catch |err| return self.clearOutbound(err);
            self.append(decimal) catch |err| return self.clearOutbound(err);
            self.append("\r\n") catch |err| return self.clearOutbound(err);
        }
        self.append(if (request.close_after_response) "Connection: close\r\n\r\n" else "Connection: keep-alive\r\n\r\n") catch |err| return self.clearOutbound(err);
        self.append(request.body) catch |err| return self.clearOutbound(err);
        self.clearResponse();
        self.parser.reset();
        self.keep_alive = !request.close_after_response;
        self.status = null;
        self.state = .awaiting_response;
        return self.outbound.items;
    }

    pub fn sendTls(self: *HttpClientConnection) HttpClientLifecycleError!tls_client.TlsClientRouteWrite {
        if (self.state != .awaiting_response) return error.InvalidState;
        const route = self.config.tls_route orelse return error.InvalidConfiguration;
        return route.send(self.outbound.items);
    }

    pub fn feed(self: *HttpClientConnection, input: []const u8) HttpClientLifecycleError!struct { consumed: usize, event: ?HttpClientEvent } {
        if (self.state != .awaiting_response) return error.InvalidState;
        const parsed = self.parser.feed(input) catch |err| {
            self.close();
            return err;
        };
        const event = parsed.event orelse return .{ .consumed = parsed.consumed, .event = null };
        switch (event) {
            .status_line => |line| self.status = line.status,
            .header => |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "connection")) self.keep_alive = !std.ascii.eqlIgnoreCase(header.value, "close");
                self.appendHeader(header) catch |err| {
                    self.close();
                    return err;
                };
            },
            .body => |bytes| {
                if (bytes.len > self.config.parser.maximum_body_bytes - self.body.items.len) return error.ResponseBodyTooLarge;
                self.body.appendSlice(self.allocator, bytes) catch |err| {
                    self.close();
                    return err;
                };
            },
            .complete => return .{ .consumed = parsed.consumed, .event = .{ .response = self.finish() } },
            else => {},
        }
        return .{ .consumed = parsed.consumed, .event = .{ .parsing = event } };
    }

    pub fn feedTls(self: *HttpClientConnection, ciphertext: []u8, plaintext: []u8) HttpClientLifecycleError!?struct { consumed: usize, event: ?HttpClientEvent } {
        const route = self.config.tls_route orelse return error.InvalidConfiguration;
        const bytes = try route.receive(ciphertext, plaintext) orelse return null;
        return try self.feed(bytes);
    }

    pub fn response(self: *const HttpClientConnection) ?HttpClientResponse {
        if (self.state != .idle and self.state != .closed) return null;
        const status = self.status orelse return null;
        return .{ .sequence = self.next_sequence -% 1, .status = status, .headers = self.headers.items, .body = self.body.items, .keep_alive = self.keep_alive, .redirect_not_followed = isRedirect(status) };
    }

    pub fn cancel(self: *HttpClientConnection) void {
        if (self.state != .awaiting_response) return;
        if (self.config.tls_route) |route| route.close();
        self.state = .cancelled;
    }

    pub fn close(self: *HttpClientConnection) void {
        if (self.state == .closed) return;
        if (self.config.tls_route) |route| route.close();
        self.state = .closed;
    }

    fn append(self: *HttpClientConnection, bytes: []const u8) HttpClientLifecycleError!void {
        if (bytes.len > self.config.maximum_request_bytes - self.outbound.items.len) return error.RequestTooLarge;
        try self.outbound.appendSlice(self.allocator, bytes);
    }

    fn clearOutbound(self: *HttpClientConnection, err: HttpClientLifecycleError) HttpClientLifecycleError {
        self.outbound.clearRetainingCapacity();
        return err;
    }

    fn appendHeader(self: *HttpClientConnection, header: protocol.HttpHeader) HttpClientLifecycleError!void {
        const name = try self.allocator.dupe(u8, header.name);
        errdefer self.allocator.free(name);
        const value = try self.allocator.dupe(u8, header.value);
        errdefer self.allocator.free(value);
        try self.headers.append(self.allocator, .{ .name = name, .value = value });
    }

    fn clearResponse(self: *HttpClientConnection) void {
        for (self.headers.items) |header| {
            self.allocator.free(header.name);
            self.allocator.free(header.value);
        }
        self.headers.clearRetainingCapacity();
        self.body.clearRetainingCapacity();
        self.status = null;
    }

    fn finish(self: *HttpClientConnection) HttpClientResponse {
        const status = self.status orelse unreachable;
        const completed = HttpClientResponse{ .sequence = self.next_sequence, .status = status, .headers = self.headers.items, .body = self.body.items, .keep_alive = self.keep_alive, .redirect_not_followed = isRedirect(status) };
        self.next_sequence +%= 1;
        if (completed.keep_alive) self.state = .idle else self.close();
        return completed;
    }
};

fn forbiddenRequestHeader(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "host") or std.ascii.eqlIgnoreCase(name, "content-length") or std.ascii.eqlIgnoreCase(name, "connection") or std.ascii.eqlIgnoreCase(name, "transfer-encoding");
}

fn validValue(value: []const u8) bool {
    for (value) |byte| if (byte == '\r' or byte == '\n' or byte == 0) return false;
    return true;
}

fn isToken(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", byte) != null;
}

fn isRedirect(status: u16) bool {
    return status >= 300 and status < 400;
}

test "HTTP clients complete fixture GETs with owned responses, reuse connections, and do not follow redirects" {
    var client = try HttpClientConnection.init(std.testing.allocator, .{ .parser = .{ .kind = .response, .maximum_start_line_bytes = 64, .maximum_header_bytes = 128, .maximum_headers = 4, .maximum_body_bytes = 16 }, .maximum_request_bytes = 128 });
    defer client.deinit();
    const first_wire = try client.begin(.{ .method = "GET", .target = "/fixture", .authority = "fixture.test" });
    try std.testing.expectEqualStrings("GET /fixture HTTP/1.1\r\nHost: fixture.test\r\nConnection: keep-alive\r\n\r\n", first_wire);
    const fixture = "HTTP/1.1 200 OK\r\nX-Fixture: yes\r\nContent-Length: 2\r\n\r\nok";
    var offset: usize = 0;
    var completed: ?HttpClientResponse = null;
    while (completed == null) {
        const result = try client.feed(fixture[offset..]);
        offset += result.consumed;
        if (result.event) |event| switch (event) {
            .response => |response| completed = response,
            else => {},
        };
    }
    const response = completed.?;
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("X-Fixture", response.headers[0].name);
    try std.testing.expectEqualStrings("yes", response.headers[0].value);
    try std.testing.expectEqualStrings("ok", response.body);
    try std.testing.expectEqual(HttpClientState.idle, client.state);

    _ = try client.begin(.{ .method = "GET", .target = "/next", .authority = "fixture.test" });
    const redirect = "HTTP/1.1 302 Found\r\nLocation: /other\r\nContent-Length: 0\r\n\r\n";
    offset = 0;
    completed = null;
    while (completed == null) {
        const result = try client.feed(redirect[offset..]);
        offset += result.consumed;
        if (result.event) |event| switch (event) {
            .response => |value| completed = value,
            else => {},
        };
    }
    try std.testing.expect(completed.?.redirect_not_followed);
    try std.testing.expectEqual(HttpClientState.idle, client.state);
}

test "HTTP clients reject request smuggling fields and cancellation prevents reuse" {
    var client = try HttpClientConnection.init(std.testing.allocator, .{});
    defer client.deinit();
    try std.testing.expectError(error.InvalidRequest, client.begin(.{ .method = "GET", .target = "/", .authority = "fixture.test", .headers = &.{.{ .name = "Host", .value = "other.test" }} }));
    _ = try client.begin(.{ .method = "GET", .target = "/", .authority = "fixture.test" });
    client.cancel();
    try std.testing.expectEqual(HttpClientState.cancelled, client.state);
    try std.testing.expectError(error.InvalidState, client.begin(.{ .method = "GET", .target = "/", .authority = "fixture.test" }));
}
