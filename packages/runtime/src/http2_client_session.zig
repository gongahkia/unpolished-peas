const std = @import("std");
const protocol = @import("minna-san-protocol");
const resource = @import("resource_handle.zig");
const service = @import("service_module.zig");
const streams = @import("http2_stream_state.zig");
const tls_alpn = @import("tls_alpn.zig");
const server = @import("http2_server_session.zig");

pub const Http2ClientSessionState = enum { awaiting_settings, ready, awaiting_response, closing, closed };
pub const Http2ClientSessionError = std.mem.Allocator.Error || protocol.Http2FrameError || protocol.HpackError || resource.HandleError || streams.Http2StreamError || error{ InvalidConfiguration, InvalidState, InvalidRequest, FirstFrameNotSettings, ResponseMalformed, ResponseBodyTooLarge, OutputTooSmall, StreamNotFound };
pub const Http2ClientHeader = struct { name: []const u8, value: []const u8 };
pub const Http2ClientRequest = struct { method: []const u8, target: []const u8, authority: []const u8, headers: []const Http2ClientHeader = &.{}, body: []const u8 = &.{} };
pub const Http2ClientResponse = struct { stream_id: u32, status: u16, body: []const u8 };
pub const Http2ClientFeed = struct { consumed: usize, response: ?Http2ClientResponse = null };

pub const Http2ClientSessionConfig = struct {
    resources: *resource.ResourceRegistry,
    transport: server.Http2TransportMode,
    negotiated_alpn: ?[]const u8 = null,
    maximum_streams: usize = 32,
    maximum_response_body_bytes: usize = protocol.max_http_body_bytes,
    maximum_header_list_bytes: usize = protocol.max_hpack_header_list_bytes,
    maximum_pending_output_bytes: usize = server.max_http2_pending_output_bytes,

    pub fn validate(self: Http2ClientSessionConfig) Http2ClientSessionError!void {
        if (self.maximum_streams == 0 or self.maximum_streams > self.resources.slots.len or self.maximum_response_body_bytes == 0 or self.maximum_header_list_bytes == 0 or self.maximum_pending_output_bytes < 64) return error.InvalidConfiguration;
        switch (self.transport) {
            .tls_alpn => if (self.negotiated_alpn == null or !std.mem.eql(u8, self.negotiated_alpn.?, tls_alpn.tls_alpn_http_2)) return error.InvalidConfiguration,
            .prior_knowledge => if (self.negotiated_alpn != null) return error.InvalidConfiguration,
        }
    }
};

const Entry = struct {
    handle: *resource.ResourceHandle,
    id: u32,
    status: ?u16 = null,
    body: std.ArrayListUnmanaged(u8) = .empty,

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        self.body.deinit(allocator);
        self.* = undefined;
    }
};

pub const Http2ClientSession = struct {
    allocator: std.mem.Allocator,
    config: Http2ClientSessionConfig,
    decoder: protocol.HpackDecoder,
    stream_registry: *streams.Http2StreamRegistry,
    entry: ?Entry = null,
    outbound: std.ArrayListUnmanaged(u8) = .empty,
    response_body: std.ArrayListUnmanaged(u8) = .empty,
    state: Http2ClientSessionState = .awaiting_settings,
    received_settings: bool = false,
    next_stream_id: u32 = 1,

    pub fn init(allocator: std.mem.Allocator, config: Http2ClientSessionConfig) Http2ClientSessionError!Http2ClientSession {
        try config.validate();
        var decoder = try protocol.HpackDecoder.init(allocator, .{ .maximum_header_list_bytes = config.maximum_header_list_bytes });
        errdefer decoder.deinit();
        const registry = try allocator.create(streams.Http2StreamRegistry);
        errdefer allocator.destroy(registry);
        registry.* = try streams.Http2StreamRegistry.init(allocator, config.resources, .{ .role = .client, .maximum_streams = config.maximum_streams });
        errdefer registry.deinit();
        var session = Http2ClientSession{ .allocator = allocator, .config = config, .decoder = decoder, .stream_registry = registry };
        try session.outbound.appendSlice(allocator, server.http2_client_preface);
        try session.queueFrame(.{ .frame_type = .settings, .flags = 0, .stream_id = 0, .payload = "" });
        return session;
    }

    pub fn deinit(self: *Http2ClientSession) void {
        if (self.entry) |*entry| {
            self.stream_registry.close(entry.handle) catch {};
            entry.deinit(self.allocator);
        }
        self.response_body.deinit(self.allocator);
        self.outbound.deinit(self.allocator);
        self.stream_registry.deinit();
        self.allocator.destroy(self.stream_registry);
        self.decoder.deinit();
        self.* = undefined;
    }

    pub fn begin(self: *Http2ClientSession, request: Http2ClientRequest) Http2ClientSessionError!u32 {
        if (self.state != .ready or self.entry != null) return error.InvalidState;
        try validateRequest(request);
        const id = self.next_stream_id;
        const handle = try self.stream_registry.create(id, .open_local, .{});
        errdefer self.stream_registry.close(handle) catch {};
        var block: std.ArrayListUnmanaged(u8) = .empty;
        defer block.deinit(self.allocator);
        try encodeRequest(self.allocator, &block, request, self.config.transport);
        try self.queueFrame(.{ .frame_type = .headers, .flags = if (request.body.len == 0) 0x5 else 0x4, .stream_id = id, .payload = block.items });
        _ = try self.stream_registry.transition(handle, .send_headers);
        if (request.body.len != 0) {
            var offset: usize = 0;
            while (offset < request.body.len) {
                const length = @min(protocol.http2_default_max_frame_bytes, request.body.len - offset);
                const final = offset + length == request.body.len;
                try self.queueFrame(.{ .frame_type = .data, .flags = if (final) 1 else 0, .stream_id = id, .payload = request.body[offset .. offset + length] });
                _ = try self.stream_registry.transition(handle, if (final) .send_end_stream else .send_data);
                offset += length;
            }
        }
        self.entry = .{ .handle = handle, .id = id };
        self.next_stream_id +%= 2;
        self.state = .awaiting_response;
        return id;
    }

    pub fn feed(self: *Http2ClientSession, input: []const u8) Http2ClientSessionError!Http2ClientFeed {
        if (self.state == .closed) return error.InvalidState;
        var consumed: usize = 0;
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

    pub fn drain(self: *Http2ClientSession, output: []u8) Http2ClientSessionError![]const u8 {
        if (output.len < self.outbound.items.len) return error.OutputTooSmall;
        @memcpy(output[0..self.outbound.items.len], self.outbound.items);
        const written = output[0..self.outbound.items.len];
        self.outbound.clearRetainingCapacity();
        return written;
    }

    pub fn shutdown(self: *Http2ClientSession) Http2ClientSessionError!void {
        if (self.state != .ready) return error.InvalidState;
        var payload: [8]u8 = undefined;
        @memset(payload[0..], 0);
        try self.queueFrame(.{ .frame_type = .goaway, .flags = 0, .stream_id = 0, .payload = &payload });
        self.state = .closing;
    }

    fn handleFrame(self: *Http2ClientSession, frame: protocol.Http2Frame) Http2ClientSessionError!?Http2ClientResponse {
        if (!self.received_settings) {
            if (frame.frame_type != .settings or frame.flags & 1 != 0) return error.FirstFrameNotSettings;
            self.received_settings = true;
            self.state = .ready;
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
            .ping => {
                if (frame.flags & 1 == 0) try self.queueFrame(.{ .frame_type = .ping, .flags = 1, .stream_id = 0, .payload = frame.payload });
                return null;
            },
            .goaway => {
                self.state = .closing;
                return null;
            },
            else => return null,
        }
    }

    fn receiveHeaders(self: *Http2ClientSession, frame: protocol.Http2Frame) Http2ClientSessionError!?Http2ClientResponse {
        const entry = self.entry orelse return error.StreamNotFound;
        if (frame.stream_id != entry.id or frame.flags & 0x28 != 0 or frame.flags & 0x4 == 0) return error.ResponseMalformed;
        var headers = try self.decoder.decode(frame.payload);
        defer headers.deinit();
        var status: ?u16 = null;
        var regular_headers = false;
        for (headers.entries.items) |header| {
            if (header.name.len == 0 or containsForbiddenByte(header.name) or containsForbiddenByte(header.value)) return error.ResponseMalformed;
            if (header.name[0] == ':') {
                if (regular_headers or !std.mem.eql(u8, header.name, ":status") or status != null or header.value.len != 3) return error.ResponseMalformed;
                status = std.fmt.parseInt(u16, header.value, 10) catch return error.ResponseMalformed;
            } else regular_headers = true;
        }
        self.entry.?.status = status orelse return error.ResponseMalformed;
        _ = try self.stream_registry.transition(entry.handle, .receive_headers);
        if (frame.flags & 1 == 0) return null;
        _ = try self.stream_registry.transition(entry.handle, .receive_end_stream);
        return try self.finish();
    }

    fn receiveData(self: *Http2ClientSession, frame: protocol.Http2Frame) Http2ClientSessionError!?Http2ClientResponse {
        const entry = self.entry orelse return error.StreamNotFound;
        if (frame.stream_id != entry.id or frame.flags & 0x8 != 0 or self.entry.?.status == null) return error.ResponseMalformed;
        if (frame.payload.len > self.config.maximum_response_body_bytes - self.entry.?.body.items.len) return error.ResponseBodyTooLarge;
        try self.entry.?.body.appendSlice(self.allocator, frame.payload);
        _ = try self.stream_registry.transition(entry.handle, .receive_data);
        if (frame.flags & 1 == 0) return null;
        _ = try self.stream_registry.transition(entry.handle, .receive_end_stream);
        return try self.finish();
    }

    fn finish(self: *Http2ClientSession) Http2ClientSessionError!Http2ClientResponse {
        var entry = self.entry orelse return error.StreamNotFound;
        const status = entry.status orelse return error.ResponseMalformed;
        self.response_body.deinit(self.allocator);
        self.response_body = entry.body;
        entry.body = .empty;
        self.stream_registry.close(entry.handle) catch {};
        self.entry = null;
        self.state = .ready;
        return .{ .stream_id = entry.id, .status = status, .body = self.response_body.items };
    }

    fn queueFrame(self: *Http2ClientSession, frame: protocol.Http2Frame) Http2ClientSessionError!void {
        const total = protocol.http2_frame_header_bytes + frame.payload.len;
        if (total > self.config.maximum_pending_output_bytes - self.outbound.items.len or frame.payload.len > protocol.http2_default_max_frame_bytes) return error.OutputTooSmall;
        var encoded: [protocol.http2_frame_header_bytes + protocol.http2_default_max_frame_bytes]u8 = undefined;
        const wire = try protocol.encode_http2_frame(.{}, frame, encoded[0..total]);
        try self.outbound.appendSlice(self.allocator, wire);
    }
};

fn validateRequest(request: Http2ClientRequest) Http2ClientSessionError!void {
    if (request.method.len == 0 or request.target.len == 0 or request.target[0] != '/' or request.authority.len == 0) return error.InvalidRequest;
    for (request.method) |byte| if (!std.ascii.isAlphanumeric(byte)) return error.InvalidRequest;
    for (request.target) |byte| if (containsForbiddenByte(&.{byte})) return error.InvalidRequest;
    for (request.headers) |header| if (header.name.len == 0 or hasUppercase(header.name) or containsForbiddenByte(header.name) or containsForbiddenByte(header.value) or isConnectionHeader(header.name)) return error.InvalidRequest;
}

fn encodeRequest(allocator: std.mem.Allocator, output: *std.ArrayListUnmanaged(u8), request: Http2ClientRequest, transport: server.Http2TransportMode) Http2ClientSessionError!void {
    if (std.mem.eql(u8, request.method, "GET")) try output.append(allocator, 0x82) else if (std.mem.eql(u8, request.method, "POST")) try output.append(allocator, 0x83) else try appendLiteral(allocator, output, ":method", request.method);
    try output.append(allocator, if (transport == .tls_alpn) 0x87 else 0x86);
    if (std.mem.eql(u8, request.target, "/")) try output.append(allocator, 0x84) else try appendLiteralIndexedName(allocator, output, 4, request.target);
    try appendLiteralIndexedName(allocator, output, 1, request.authority);
    for (request.headers) |header| try appendLiteral(allocator, output, header.name, header.value);
}

fn appendLiteralIndexedName(allocator: std.mem.Allocator, output: *std.ArrayListUnmanaged(u8), index: usize, value: []const u8) Http2ClientSessionError!void {
    try appendInteger(allocator, output, 0x40, 6, index);
    try appendString(allocator, output, value);
}

fn appendLiteral(allocator: std.mem.Allocator, output: *std.ArrayListUnmanaged(u8), name: []const u8, value: []const u8) Http2ClientSessionError!void {
    try output.append(allocator, 0);
    try appendString(allocator, output, name);
    try appendString(allocator, output, value);
}

fn appendString(allocator: std.mem.Allocator, output: *std.ArrayListUnmanaged(u8), value: []const u8) Http2ClientSessionError!void {
    try appendInteger(allocator, output, 0, 7, value.len);
    try output.appendSlice(allocator, value);
}

fn appendInteger(allocator: std.mem.Allocator, output: *std.ArrayListUnmanaged(u8), prefix_bits: u8, comptime prefix: u3, initial: usize) Http2ClientSessionError!void {
    const maximum: usize = (@as(usize, 1) << prefix) - 1;
    var value = initial;
    if (value < maximum) return output.append(allocator, prefix_bits | @as(u8, @intCast(value)));
    try output.append(allocator, prefix_bits | @as(u8, @intCast(maximum)));
    value -= maximum;
    while (value >= 128) : (value /= 128) try output.append(allocator, @as(u8, @intCast(value % 128)) | 0x80);
    try output.append(allocator, @intCast(value));
}

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

test "HTTP2 client sessions exchange prefaced settings and routed responses" {
    const Fixture = struct {
        fn route(_: ?*anyopaque, request: service.ServiceRequest) service.ServiceModuleError!service.ServiceRouteResult {
            if (!std.mem.eql(u8, "/public", request.route)) return error.CallbackFailed;
            return .handled;
        }
    };
    var services = try service.ServiceRegistry.init(std.testing.allocator, .{ .maximum_modules = 1 });
    defer services.deinit();
    _ = try services.register(.{ .config = .{ .name = "public", .route_prefix = "/public", .maximum_state_bytes = 1 }, .context = null, .hooks = .{ .route = Fixture.route } });
    try services.start();
    var server_resources = try resource.ResourceRegistry.init(std.testing.allocator, 1);
    defer server_resources.deinit();
    var client_resources = try resource.ResourceRegistry.init(std.testing.allocator, 1);
    defer client_resources.deinit();
    var server_session = try server.Http2ServerSession.init(std.testing.allocator, .{ .services = &services, .resources = &server_resources, .transport = .prior_knowledge, .maximum_streams = 1 });
    defer server_session.deinit();
    var client_session = try Http2ClientSession.init(std.testing.allocator, .{ .resources = &client_resources, .transport = .prior_knowledge, .maximum_streams = 1 });
    defer client_session.deinit();
    var wire: [512]u8 = undefined;
    _ = try server_session.feed(try client_session.drain(wire[0..]));
    _ = try client_session.feed(try server_session.drain(wire[0..]));
    _ = try server_session.feed(try client_session.drain(wire[0..]));
    const stream = try client_session.begin(.{ .method = "GET", .target = "/public", .authority = "fixture.test" });
    const server_result = try server_session.feed(try client_session.drain(wire[0..]));
    try std.testing.expectEqual(@as(u32, 1), stream);
    try std.testing.expectEqual(@as(u16, 200), server_result.response.?.status);
    const response = try client_session.feed(try server_session.drain(wire[0..]));
    try std.testing.expectEqual(@as(u16, 200), response.response.?.status);
    try std.testing.expectEqual(@as(usize, 0), response.response.?.body.len);
}
