const std = @import("std");
const protocol = @import("minna-san-protocol");
const resource = @import("resource_handle.zig");
const service = @import("service_module.zig");
const streams = @import("http2_stream_state.zig");
const flow_control = @import("http2_flow_control.zig");
const tls_alpn = @import("tls_alpn.zig");

pub const http2_client_preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
pub const max_http2_pending_output_bytes: usize = 128 * 1024;
pub const Http2TransportMode = enum { tls_alpn, prior_knowledge };
pub const Http2ServerSessionState = enum { awaiting_preface, awaiting_settings, open, closing, closed };
pub const Http2ServerSessionError = std.mem.Allocator.Error || protocol.Http2FrameError || protocol.HpackError || resource.HandleError || service.ServiceModuleError || streams.Http2StreamError || flow_control.Http2FlowControlError || error{ InvalidConfiguration, InvalidState, InvalidPreface, FirstFrameNotSettings, RequestMalformed, RequestBodyTooLarge, StreamNotFound, StreamOrderViolation, HeaderBlockIncomplete, OutputTooSmall };
pub const Http2ServerResponse = struct { stream_id: u32, status: u16, dispatch: ?service.ServiceDispatch = null };
pub const Http2ServerFeed = struct { consumed: usize, response: ?Http2ServerResponse = null };

pub const Http2ServerSessionConfig = struct {
    services: *service.ServiceRegistry,
    resources: *resource.ResourceRegistry,
    transport: Http2TransportMode,
    negotiated_alpn: ?[]const u8 = null,
    maximum_streams: usize = 32,
    maximum_request_body_bytes: usize = protocol.max_http_body_bytes,
    maximum_header_list_bytes: usize = protocol.max_hpack_header_list_bytes,
    maximum_pending_output_bytes: usize = max_http2_pending_output_bytes,

    pub fn validate(self: Http2ServerSessionConfig) Http2ServerSessionError!void {
        if (self.maximum_streams == 0 or self.maximum_streams > self.resources.slots.len or self.maximum_request_body_bytes == 0 or self.maximum_header_list_bytes == 0 or self.maximum_pending_output_bytes < 64) return error.InvalidConfiguration;
        switch (self.transport) {
            .tls_alpn => if (self.negotiated_alpn == null or !std.mem.eql(u8, self.negotiated_alpn.?, tls_alpn.tls_alpn_http_2)) return error.InvalidConfiguration,
            .prior_knowledge => if (self.negotiated_alpn != null) return error.InvalidConfiguration,
        }
    }
};

const RequestEntry = struct {
    handle: *resource.ResourceHandle,
    id: u32,
    path: std.ArrayListUnmanaged(u8) = .empty,
    credentials: std.ArrayListUnmanaged(u8) = .empty,
    body: std.ArrayListUnmanaged(u8) = .empty,

    fn deinit(self: *RequestEntry, allocator: std.mem.Allocator) void {
        self.path.deinit(allocator);
        self.credentials.deinit(allocator);
        self.body.deinit(allocator);
        self.* = undefined;
    }
};

pub const Http2ServerSession = struct {
    allocator: std.mem.Allocator,
    config: Http2ServerSessionConfig,
    decoder: protocol.HpackDecoder,
    stream_registry: *streams.Http2StreamRegistry,
    flow: flow_control.Http2FlowController,
    entries: std.ArrayListUnmanaged(RequestEntry) = .empty,
    outbound: std.ArrayListUnmanaged(u8) = .empty,
    state: Http2ServerSessionState = .awaiting_preface,
    preface_bytes: usize = 0,
    received_settings: bool = false,
    last_remote_stream_id: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, config: Http2ServerSessionConfig) Http2ServerSessionError!Http2ServerSession {
        try config.validate();
        var decoder = try protocol.HpackDecoder.init(allocator, .{ .maximum_header_list_bytes = config.maximum_header_list_bytes });
        errdefer decoder.deinit();
        const registry = try allocator.create(streams.Http2StreamRegistry);
        errdefer allocator.destroy(registry);
        registry.* = try streams.Http2StreamRegistry.init(allocator, config.resources, .{ .role = .server, .maximum_streams = config.maximum_streams });
        errdefer registry.deinit();
        var flow = try flow_control.Http2FlowController.init(allocator, .{ .stream_registry = registry, .maximum_streams = config.maximum_streams, .maximum_buffered_bytes_per_stream = config.maximum_request_body_bytes });
        errdefer flow.deinit();
        return .{ .allocator = allocator, .config = config, .decoder = decoder, .stream_registry = registry, .flow = flow };
    }

    pub fn deinit(self: *Http2ServerSession) void {
        while (self.entries.items.len != 0) self.dropEntry(self.entries.items.len - 1);
        self.entries.deinit(self.allocator);
        self.outbound.deinit(self.allocator);
        self.flow.deinit();
        self.stream_registry.deinit();
        self.allocator.destroy(self.stream_registry);
        self.decoder.deinit();
        self.* = undefined;
    }

    pub fn feed(self: *Http2ServerSession, input: []const u8) Http2ServerSessionError!Http2ServerFeed {
        if (self.state == .closing or self.state == .closed) return error.InvalidState;
        var consumed: usize = 0;
        if (self.state == .awaiting_preface) {
            while (consumed < input.len and self.preface_bytes < http2_client_preface.len) {
                if (input[consumed] != http2_client_preface[self.preface_bytes]) return error.InvalidPreface;
                consumed += 1;
                self.preface_bytes += 1;
            }
            if (self.preface_bytes != http2_client_preface.len) return .{ .consumed = consumed };
            self.state = .awaiting_settings;
            try self.queueFrame(.{ .frame_type = .settings, .flags = 0, .stream_id = 0, .payload = "" });
        }
        while (consumed < input.len) {
            const decoded = protocol.decode_http2_frame(.{}, input[consumed..]) catch |err| switch (err) {
                error.IncompleteFrame => return .{ .consumed = consumed },
                else => return err,
            };
            consumed += decoded.consumed;
            if (try self.handleFrame(decoded.frame)) |response| return .{ .consumed = consumed, .response = response };
        }
        return .{ .consumed = consumed };
    }

    pub fn drain(self: *Http2ServerSession, output: []u8) Http2ServerSessionError![]const u8 {
        if (output.len < self.outbound.items.len) return error.OutputTooSmall;
        @memcpy(output[0..self.outbound.items.len], self.outbound.items);
        const written = output[0..self.outbound.items.len];
        self.outbound.clearRetainingCapacity();
        return written;
    }

    pub fn shutdown(self: *Http2ServerSession) Http2ServerSessionError!void {
        if (self.state != .open) return error.InvalidState;
        var payload: [8]u8 = undefined;
        std.mem.writeInt(u32, payload[0..4], self.last_remote_stream_id, .big);
        @memset(payload[4..], 0);
        try self.queueFrame(.{ .frame_type = .goaway, .flags = 0, .stream_id = 0, .payload = &payload });
        self.state = .closing;
    }

    fn handleFrame(self: *Http2ServerSession, frame: protocol.Http2Frame) Http2ServerSessionError!?Http2ServerResponse {
        if (!self.received_settings) {
            if (frame.frame_type != .settings or frame.flags & 1 != 0) return error.FirstFrameNotSettings;
            self.received_settings = true;
            self.state = .open;
            try self.queueFrame(.{ .frame_type = .settings, .flags = 1, .stream_id = 0, .payload = "" });
            return null;
        }
        switch (frame.frame_type) {
            .settings => {
                if (frame.flags & 1 == 0) try self.queueFrame(.{ .frame_type = .settings, .flags = 1, .stream_id = 0, .payload = "" });
                return null;
            },
            .headers => return try self.receiveHeaders(frame),
            .data => return try self.receiveData(frame),
            .rst_stream => {
                const index = self.findEntry(frame.stream_id) orelse return error.StreamNotFound;
                self.dropEntry(index);
                return null;
            },
            .window_update => {
                const increment = std.mem.readInt(u32, frame.payload[0..4], .big);
                if (frame.stream_id == 0) try self.flow.receiveWindowUpdate(null, increment) else {
                    const index = self.findEntry(frame.stream_id) orelse return error.StreamNotFound;
                    try self.flow.receiveWindowUpdate(self.entries.items[index].handle, increment);
                }
                return null;
            },
            .ping => {
                if (frame.flags & 1 == 0) try self.queueFrame(.{ .frame_type = .ping, .flags = 1, .stream_id = 0, .payload = frame.payload });
                return null;
            },
            .goaway => {
                self.state = .closing;
                return null;
            },
            .continuation => return error.HeaderBlockIncomplete,
            else => return null,
        }
    }

    fn receiveHeaders(self: *Http2ServerSession, frame: protocol.Http2Frame) Http2ServerSessionError!?Http2ServerResponse {
        if (frame.flags & 0x28 != 0) return error.RequestMalformed;
        if (frame.flags & 0x4 == 0) return error.HeaderBlockIncomplete;
        if (frame.stream_id <= self.last_remote_stream_id or frame.stream_id & 1 == 0) return error.StreamOrderViolation;
        self.last_remote_stream_id = frame.stream_id;
        var headers = try self.decoder.decode(frame.payload);
        defer headers.deinit();
        var path: ?[]const u8 = null;
        var method: ?[]const u8 = null;
        var scheme: ?[]const u8 = null;
        var authority: ?[]const u8 = null;
        var credentials: ?[]const u8 = null;
        var regular_headers = false;
        for (headers.entries.items) |header| {
            if (header.name.len == 0 or containsForbiddenByte(header.name) or containsForbiddenByte(header.value)) return error.RequestMalformed;
            if (header.name[0] == ':') {
                if (regular_headers) return error.RequestMalformed;
                if (std.mem.eql(u8, header.name, ":method")) {
                    if (method != null) return error.RequestMalformed;
                    method = header.value;
                } else if (std.mem.eql(u8, header.name, ":path")) {
                    if (path != null) return error.RequestMalformed;
                    path = header.value;
                } else if (std.mem.eql(u8, header.name, ":scheme")) {
                    if (scheme != null) return error.RequestMalformed;
                    scheme = header.value;
                } else if (std.mem.eql(u8, header.name, ":authority")) {
                    if (authority != null) return error.RequestMalformed;
                    authority = header.value;
                } else return error.RequestMalformed;
            } else {
                regular_headers = true;
                if (hasUppercase(header.name) or isConnectionHeader(header.name)) return error.RequestMalformed;
                if (std.mem.eql(u8, header.name, "authorization")) {
                    if (credentials != null) return error.RequestMalformed;
                    credentials = header.value;
                }
            }
        }
        if (method == null or path == null or scheme == null or authority == null or path.?.len == 0 or path.?[0] != '/') return error.RequestMalformed;
        const handle = try self.stream_registry.create(frame.stream_id, .open_remote, .{});
        errdefer self.stream_registry.close(handle) catch {};
        try self.flow.attach(handle);
        _ = try self.stream_registry.transition(handle, .receive_headers);
        var entry = RequestEntry{ .handle = handle, .id = frame.stream_id };
        errdefer entry.deinit(self.allocator);
        try entry.path.appendSlice(self.allocator, path.?);
        if (credentials) |value| try entry.credentials.appendSlice(self.allocator, value);
        try self.entries.append(self.allocator, entry);
        if (frame.flags & 1 == 0) return null;
        _ = try self.stream_registry.transition(handle, .receive_end_stream);
        return try self.completeRequest(self.entries.items.len - 1);
    }

    fn receiveData(self: *Http2ServerSession, frame: protocol.Http2Frame) Http2ServerSessionError!?Http2ServerResponse {
        if (frame.flags & 0x8 != 0) return error.RequestMalformed;
        const index = self.findEntry(frame.stream_id) orelse return error.StreamNotFound;
        var entry = &self.entries.items[index];
        if (frame.payload.len > self.config.maximum_request_body_bytes - entry.body.items.len) return error.RequestBodyTooLarge;
        try entry.body.appendSlice(self.allocator, frame.payload);
        _ = try self.stream_registry.transition(entry.handle, .receive_data);
        if (frame.flags & 1 == 0) return null;
        _ = try self.stream_registry.transition(entry.handle, .receive_end_stream);
        return try self.completeRequest(index);
    }

    fn completeRequest(self: *Http2ServerSession, index: usize) Http2ServerSessionError!Http2ServerResponse {
        const entry = &self.entries.items[index];
        const route_dispatch = self.config.services.dispatch(.{ .route = entry.path.items, .credentials = entry.credentials.items, .payload = entry.body.items }) catch |err| switch (err) {
            error.RouteNotFound => return self.finish(index, 404, null),
            error.CredentialRejected => return self.finish(index, 401, null),
            else => return self.finish(index, 500, null),
        };
        return self.finish(index, if (route_dispatch.result == .handled) 200 else 404, route_dispatch);
    }

    fn finish(self: *Http2ServerSession, index: usize, status: u16, response_dispatch: ?service.ServiceDispatch) Http2ServerSessionError!Http2ServerResponse {
        const entry = self.entries.items[index];
        const block = switch (status) {
            200 => "\x88",
            401 => "\x08\x03\x34\x30\x31",
            404 => "\x8d",
            else => "\x8e",
        };
        _ = try self.stream_registry.transition(entry.handle, .send_headers);
        try self.queueFrame(.{ .frame_type = .headers, .flags = 0x5, .stream_id = entry.id, .payload = block });
        _ = try self.stream_registry.transition(entry.handle, .send_end_stream);
        const response = Http2ServerResponse{ .stream_id = entry.id, .status = status, .dispatch = response_dispatch };
        self.dropEntry(index);
        return response;
    }

    fn queueFrame(self: *Http2ServerSession, frame: protocol.Http2Frame) Http2ServerSessionError!void {
        const total = protocol.http2_frame_header_bytes + frame.payload.len;
        if (total > self.config.maximum_pending_output_bytes - self.outbound.items.len) return error.OutputTooSmall;
        if (frame.payload.len > protocol.http2_default_max_frame_bytes) return error.OutputTooSmall;
        var encoded: [protocol.http2_frame_header_bytes + protocol.http2_default_max_frame_bytes]u8 = undefined;
        const wire = try protocol.encode_http2_frame(.{}, frame, encoded[0..total]);
        try self.outbound.appendSlice(self.allocator, wire);
    }

    fn findEntry(self: *const Http2ServerSession, id: u32) ?usize {
        for (self.entries.items, 0..) |entry, index| if (entry.id == id) return index;
        return null;
    }

    fn dropEntry(self: *Http2ServerSession, index: usize) void {
        var entry = self.entries.orderedRemove(index);
        self.stream_registry.close(entry.handle) catch {};
        entry.deinit(self.allocator);
    }
};

fn containsForbiddenByte(value: []const u8) bool {
    for (value) |byte| if (byte == 0 or byte == '\r' or byte == '\n') return true;
    return false;
}

fn hasUppercase(value: []const u8) bool {
    for (value) |byte| if (byte >= 'A' and byte <= 'Z') return true;
    return false;
}

fn isConnectionHeader(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "connection") or std.ascii.eqlIgnoreCase(value, "keep-alive") or std.ascii.eqlIgnoreCase(value, "proxy-connection") or std.ascii.eqlIgnoreCase(value, "transfer-encoding") or std.ascii.eqlIgnoreCase(value, "upgrade");
}

test "HTTP2 server sessions route curl-compatible headers after preface and settings" {
    const Fixture = struct {
        calls: usize = 0,

        fn route(context: ?*anyopaque, request: service.ServiceRequest) service.ServiceModuleError!service.ServiceRouteResult {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (!std.mem.eql(u8, "/public", request.route)) return error.CallbackFailed;
            self.calls += 1;
            return .handled;
        }
    };
    var fixture = Fixture{};
    var services = try service.ServiceRegistry.init(std.testing.allocator, .{ .maximum_modules = 1 });
    defer services.deinit();
    _ = try services.register(.{ .config = .{ .name = "public", .route_prefix = "/public", .maximum_state_bytes = 1 }, .context = &fixture, .hooks = .{ .route = Fixture.route } });
    try services.start();
    var resources = try resource.ResourceRegistry.init(std.testing.allocator, 2);
    defer resources.deinit();
    var session = try Http2ServerSession.init(std.testing.allocator, .{ .services = &services, .resources = &resources, .transport = .prior_knowledge, .maximum_streams = 2 });
    defer session.deinit();
    const request = http2_client_preface ++ "\x00\x00\x00\x04\x00\x00\x00\x00\x00" ++ "\x00\x00\x25\x01\x05\x00\x00\x00\x01\x82\x86\x41\x8b\x08\x9d\x5c\x0b\x81\x70\xdc\x69\xb7\x9f\x0f\x04\x85\x62\xbb\x63\xa0\xc4\x7a\x88\x25\xb6\x50\xc3\xcb\xba\xb8\x7f\x53\x03\x2a\x2f\x2a";
    const result = try session.feed(request);
    try std.testing.expectEqual(request.len, result.consumed);
    try std.testing.expectEqual(@as(u16, 200), result.response.?.status);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    var outbound: [64]u8 = undefined;
    const wire = try session.drain(outbound[0..]);
    const settings = try protocol.decode_http2_frame(.{}, wire);
    try std.testing.expectEqual(protocol.Http2FrameType.settings, settings.frame.frame_type);
    const acknowledgement = try protocol.decode_http2_frame(.{}, wire[settings.consumed..]);
    try std.testing.expect(acknowledgement.frame.flags & 1 != 0);
    const response = try protocol.decode_http2_frame(.{}, wire[settings.consumed + acknowledgement.consumed ..]);
    try std.testing.expectEqual(protocol.Http2FrameType.headers, response.frame.frame_type);
    try std.testing.expectEqual(@as(u8, 0x5), response.frame.flags);
    try std.testing.expectEqualStrings("\x88", response.frame.payload);
}

test "HTTP2 TLS sessions require negotiated h2 and emit graceful GOAWAY" {
    var services = try service.ServiceRegistry.init(std.testing.allocator, .{ .maximum_modules = 0 });
    defer services.deinit();
    var resources = try resource.ResourceRegistry.init(std.testing.allocator, 1);
    defer resources.deinit();
    try std.testing.expectError(error.InvalidConfiguration, Http2ServerSession.init(std.testing.allocator, .{ .services = &services, .resources = &resources, .transport = .tls_alpn, .negotiated_alpn = tls_alpn.tls_alpn_http_1_1, .maximum_streams = 1 }));
    var session = try Http2ServerSession.init(std.testing.allocator, .{ .services = &services, .resources = &resources, .transport = .tls_alpn, .negotiated_alpn = tls_alpn.tls_alpn_http_2, .maximum_streams = 1 });
    defer session.deinit();
    _ = try session.feed(http2_client_preface ++ "\x00\x00\x00\x04\x00\x00\x00\x00\x00");
    try session.shutdown();
    var outbound: [64]u8 = undefined;
    const wire = try session.drain(outbound[0..]);
    const settings = try protocol.decode_http2_frame(.{}, wire);
    const acknowledgement = try protocol.decode_http2_frame(.{}, wire[settings.consumed..]);
    const goaway = try protocol.decode_http2_frame(.{}, wire[settings.consumed + acknowledgement.consumed ..]);
    try std.testing.expectEqual(protocol.Http2FrameType.goaway, goaway.frame.frame_type);
}

test "external curl HTTP2 client calls a public fixture route" {
    const Fixture = struct {
        fn route(_: ?*anyopaque, request: service.ServiceRequest) service.ServiceModuleError!service.ServiceRouteResult {
            if (!std.mem.eql(u8, "/public", request.route)) return error.CallbackFailed;
            return .handled;
        }
    };
    const listener = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, std.posix.IPPROTO.TCP);
    defer std.posix.close(listener);
    var address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    try std.posix.bind(listener, &address.any, address.getOsSockLen());
    try std.posix.listen(listener, 1);
    var address_length = address.getOsSockLen();
    try std.posix.getsockname(listener, &address.any, &address_length);
    var url: [64]u8 = undefined;
    const request_url = try std.fmt.bufPrint(url[0..], "http://127.0.0.1:{d}/public", .{address.in.getPort()});
    var client = std.process.Child.init(&.{ "curl", "--http2-prior-knowledge", "--fail", "--silent", request_url }, std.testing.allocator);
    client.stdout_behavior = .Ignore;
    client.stderr_behavior = .Ignore;
    try client.spawn();
    errdefer _ = client.kill() catch {};
    var peer_address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
    var peer_length = peer_address.getOsSockLen();
    const connection = try std.posix.accept(listener, &peer_address.any, &peer_length, std.posix.SOCK.CLOEXEC);
    defer std.posix.close(connection);
    var services = try service.ServiceRegistry.init(std.testing.allocator, .{ .maximum_modules = 1 });
    defer services.deinit();
    _ = try services.register(.{ .config = .{ .name = "public", .route_prefix = "/public", .maximum_state_bytes = 1 }, .context = null, .hooks = .{ .route = Fixture.route } });
    try services.start();
    var resources = try resource.ResourceRegistry.init(std.testing.allocator, 1);
    defer resources.deinit();
    var session = try Http2ServerSession.init(std.testing.allocator, .{ .services = &services, .resources = &resources, .transport = .prior_knowledge, .maximum_streams = 1 });
    defer session.deinit();
    var input: [64 * 1024]u8 = undefined;
    var used: usize = 0;
    var response_sent = false;
    while (!response_sent) {
        if (used == input.len) return error.TestExpectedEqual;
        const received = try std.posix.recv(connection, input[used..], 0);
        if (received == 0) return error.TestExpectedEqual;
        used += received;
        while (used != 0) {
            const result = try session.feed(input[0..used]);
            if (result.consumed != 0) {
                const remaining = used - result.consumed;
                std.mem.copyForwards(u8, input[0..remaining], input[result.consumed..used]);
                used = remaining;
            }
            if (session.outbound.items.len != 0) {
                var outbound: [64 * 1024]u8 = undefined;
                try sendAll(connection, try session.drain(outbound[0..]));
            }
            if (result.response != null) {
                response_sent = true;
                break;
            }
            if (result.consumed == 0) break;
        }
    }
    const term = try client.wait();
    try std.testing.expect(switch (term) {
        .Exited => |code| code == 0,
        else => false,
    });
}

fn sendAll(socket: std.posix.socket_t, bytes: []const u8) !void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const count = try std.posix.send(socket, bytes[sent..], 0);
        if (count == 0) return error.WriteFailed;
        sent += count;
    }
}
