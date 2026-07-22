const std = @import("std");
const protocol = @import("minna-san-protocol");
const resource = @import("resource_handle.zig");
const service = @import("service_module.zig");
const control = @import("http3_control_session.zig");

pub const max_http3_request_streams: usize = 64;
pub const max_http3_request_header_bytes: usize = 16 * 1024;
pub const max_http3_request_pending_output_bytes: usize = 128 * 1024;

pub const Http3RequestStreamState = enum(u8) {
    awaiting_headers,
    receiving_body,
    complete,
    cancelled,
};

pub const Http3HeaderCallback = *const fn (?*anyopaque, [*]const u8, usize, [*]const u8, usize) callconv(.c) c_int;

pub const Http3HeaderProviderVTable = extern struct {
    decode_request: *const fn (?*anyopaque, [*]const u8, usize, ?*anyopaque, Http3HeaderCallback) callconv(.c) c_int,
    encode_response: *const fn (?*anyopaque, u16, [*]u8, usize, *usize) callconv(.c) c_int,
};

pub const Http3RequestStreamProviderVTable = extern struct {
    cancel: *const fn (?*anyopaque, u64, u64) callconv(.c) void,
};

pub const Http3RequestStreamConfig = struct {
    services: *service.ServiceRegistry,
    codec: protocol.Http3ControlCodecConfig = .{},
    maximum_streams: usize = 32,
    maximum_request_body_bytes: usize = protocol.max_http_body_bytes,
    maximum_header_bytes: usize = max_http3_request_header_bytes,
    maximum_pending_output_bytes: usize = max_http3_request_pending_output_bytes,

    pub fn validate(self: Http3RequestStreamConfig) Http3RequestStreamError!void {
        try self.codec.validate();
        if (self.maximum_streams == 0 or self.maximum_streams > max_http3_request_streams or self.maximum_request_body_bytes == 0 or self.maximum_header_bytes == 0 or self.maximum_header_bytes > self.codec.maximum_frame_bytes or self.maximum_pending_output_bytes == 0 or self.maximum_pending_output_bytes > max_http3_request_pending_output_bytes) return error.InvalidConfiguration;
    }
};

pub const Http3RequestResponse = struct {
    stream_id: u64,
    status: u16,
    dispatch: ?service.ServiceDispatch = null,
};

pub const Http3ResponseWrite = struct {
    stream_id: u64,
    end_stream: bool,
    bytes: []const u8,
};

pub const Http3RequestStreamStatus = struct {
    stream_id: u64,
    state: Http3RequestStreamState,
    body_bytes: usize,
};

pub const Http3RequestStreamError = std.mem.Allocator.Error || protocol.Http3ControlCodecError || resource.HandleError || service.ServiceModuleError || control.Http3ControlSessionError || error{ InvalidConfiguration, InvalidState, ControlNotReady, StreamCapacityExceeded, UnknownStream, RequestMalformed, RequestHeaderTooLarge, RequestBodyTooLarge, ProviderFailed, OutputTooSmall, IncompleteRequest };

const Entry = struct {
    stream_id: u64,
    state: Http3RequestStreamState = .awaiting_headers,
    headers_received: bool = false,
    path: std.ArrayListUnmanaged(u8) = .empty,
    credentials: std.ArrayListUnmanaged(u8) = .empty,
    body: std.ArrayListUnmanaged(u8) = .empty,
    inbound: std.ArrayListUnmanaged(u8) = .empty,
    inbound_offset: usize = 0,

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        self.path.deinit(allocator);
        self.credentials.deinit(allocator);
        self.body.deinit(allocator);
        self.inbound.deinit(allocator);
        self.* = undefined;
    }
};

const Outbound = struct {
    stream_id: u64,
    bytes: []u8,

    fn deinit(self: *Outbound, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const Http3RequestStreamAdapter = struct {
    allocator: std.mem.Allocator,
    control_session: *control.Http3ControlSession,
    config: Http3RequestStreamConfig,
    header_context: ?*anyopaque,
    header_vtable: Http3HeaderProviderVTable,
    stream_context: ?*anyopaque,
    stream_vtable: Http3RequestStreamProviderVTable,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    outbound: std.ArrayListUnmanaged(Outbound) = .empty,
    pending_output_bytes: usize = 0,

    pub fn init(allocator: std.mem.Allocator, control_session: *control.Http3ControlSession, config: Http3RequestStreamConfig, header_context: ?*anyopaque, header_vtable: Http3HeaderProviderVTable, stream_context: ?*anyopaque, stream_vtable: Http3RequestStreamProviderVTable) Http3RequestStreamError!Http3RequestStreamAdapter {
        try config.validate();
        if (control_session.status().state != .open) return error.ControlNotReady;
        return .{ .allocator = allocator, .control_session = control_session, .config = config, .header_context = header_context, .header_vtable = header_vtable, .stream_context = stream_context, .stream_vtable = stream_vtable };
    }

    pub fn deinit(self: *Http3RequestStreamAdapter) void {
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        for (self.outbound.items) |*entry| entry.deinit(self.allocator);
        self.outbound.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn feed(self: *Http3RequestStreamAdapter, stream_id: u64, input: []const u8) Http3RequestStreamError!usize {
        if (self.control_session.status().state != .open) return error.ControlNotReady;
        const entry = try self.entryForStream(stream_id);
        if (entry.state == .complete or entry.state == .cancelled) return error.InvalidState;
        try compactInbound(entry);
        if (input.len > self.config.codec.maximum_frame_bytes - entry.inbound.items.len) return error.RequestBodyTooLarge;
        try entry.inbound.appendSlice(self.allocator, input);
        while (entry.inbound_offset < entry.inbound.items.len) {
            const decoded = protocol.decode_http3_control_frame(self.config.codec, entry.inbound.items[entry.inbound_offset..]) catch |err| switch (err) {
                error.IncompleteFrame => break,
                else => return err,
            };
            try self.handleFrame(entry, decoded.frame);
            entry.inbound_offset += decoded.consumed;
        }
        try compactInbound(entry);
        return input.len;
    }

    pub fn finish(self: *Http3RequestStreamAdapter, stream_id: u64) Http3RequestStreamError!Http3RequestResponse {
        const index = self.indexForStream(stream_id) orelse return error.UnknownStream;
        const entry = &self.entries.items[index];
        if (!entry.headers_received) return error.IncompleteRequest;
        if (entry.state != .receiving_body) return error.InvalidState;
        const dispatch = self.config.services.dispatch(.{ .route = entry.path.items, .credentials = entry.credentials.items, .payload = entry.body.items }) catch |err| switch (err) {
            error.RouteNotFound => return self.complete(index, 404, null),
            error.CredentialRejected => return self.complete(index, 401, null),
            else => return self.complete(index, 500, null),
        };
        return self.complete(index, if (dispatch.result == .handled) 200 else 404, dispatch);
    }

    pub fn cancel(self: *Http3RequestStreamAdapter, stream_id: u64, error_code: control.Http3ErrorCode) Http3RequestStreamError!void {
        const index = self.indexForStream(stream_id) orelse return error.UnknownStream;
        self.stream_vtable.cancel(self.stream_context, stream_id, @intFromEnum(error_code));
        self.dropEntry(index);
    }

    pub fn status(self: *const Http3RequestStreamAdapter, stream_id: u64) Http3RequestStreamError!Http3RequestStreamStatus {
        const index = self.indexForStream(stream_id) orelse return error.UnknownStream;
        const entry = self.entries.items[index];
        return .{ .stream_id = entry.stream_id, .state = entry.state, .body_bytes = entry.body.items.len };
    }

    pub fn drainResponse(self: *Http3RequestStreamAdapter, output: []u8) Http3RequestStreamError!?Http3ResponseWrite {
        if (self.outbound.items.len == 0) return null;
        var next = self.outbound.orderedRemove(0);
        if (output.len < next.bytes.len) {
            try self.outbound.insert(self.allocator, 0, next);
            return error.OutputTooSmall;
        }
        defer next.deinit(self.allocator);
        @memcpy(output[0..next.bytes.len], next.bytes);
        self.pending_output_bytes -= next.bytes.len;
        return .{ .stream_id = next.stream_id, .end_stream = true, .bytes = output[0..next.bytes.len] };
    }

    fn entryForStream(self: *Http3RequestStreamAdapter, stream_id: u64) Http3RequestStreamError!*Entry {
        if (self.indexForStream(stream_id)) |index| return &self.entries.items[index];
        if (self.entries.items.len == self.config.maximum_streams) return error.StreamCapacityExceeded;
        try self.entries.append(self.allocator, .{ .stream_id = stream_id });
        return &self.entries.items[self.entries.items.len - 1];
    }

    fn indexForStream(self: *const Http3RequestStreamAdapter, stream_id: u64) ?usize {
        for (self.entries.items, 0..) |entry, index| if (entry.stream_id == stream_id) return index;
        return null;
    }

    fn handleFrame(self: *Http3RequestStreamAdapter, entry: *Entry, frame: protocol.Http3ControlFrame) Http3RequestStreamError!void {
        switch (@as(protocol.Http3FrameType, @enumFromInt(frame.frame_type))) {
            .headers => {
                if (entry.headers_received) return error.RequestMalformed;
                try self.decodeRequestHeaders(entry, frame.payload);
                entry.headers_received = true;
                entry.state = .receiving_body;
            },
            .data => {
                if (!entry.headers_received or entry.state != .receiving_body) return error.RequestMalformed;
                if (frame.payload.len > self.config.maximum_request_body_bytes - entry.body.items.len) return error.RequestBodyTooLarge;
                try entry.body.appendSlice(self.allocator, frame.payload);
            },
            .settings, .cancel_push, .push_promise, .goaway, .max_push_id => return error.RequestMalformed,
            else => {},
        }
    }

    fn decodeRequestHeaders(self: *Http3RequestStreamAdapter, entry: *Entry, payload: []const u8) Http3RequestStreamError!void {
        var collector = HeaderCollector{ .allocator = self.allocator, .maximum_header_bytes = self.config.maximum_header_bytes, .entry = entry };
        if (self.header_vtable.decode_request(self.header_context, payload.ptr, payload.len, &collector, HeaderCollector.callback) != 0) {
            if (collector.failure) |failure| return failure;
            return error.ProviderFailed;
        }
        if (collector.failure) |failure| return failure;
        try collector.validate();
    }

    fn complete(self: *Http3RequestStreamAdapter, index: usize, status_code: u16, dispatch: ?service.ServiceDispatch) Http3RequestStreamError!Http3RequestResponse {
        const stream_id = self.entries.items[index].stream_id;
        try self.queueResponse(stream_id, status_code);
        self.dropEntry(index);
        return .{ .stream_id = stream_id, .status = status_code, .dispatch = dispatch };
    }

    fn queueResponse(self: *Http3RequestStreamAdapter, stream_id: u64, status_code: u16) Http3RequestStreamError!void {
        var header_block = try self.allocator.alloc(u8, self.config.maximum_header_bytes);
        defer self.allocator.free(header_block);
        var header_len: usize = 0;
        if (self.header_vtable.encode_response(self.header_context, status_code, header_block.ptr, header_block.len, &header_len) != 0 or header_len > header_block.len) return error.ProviderFailed;
        const frame = protocol.Http3ControlFrame{ .frame_type = @intFromEnum(protocol.Http3FrameType.headers), .payload = header_block[0..header_len] };
        const frame_len = try protocol.http3_control_frame_encoded_len(self.config.codec, frame);
        if (frame_len > self.config.maximum_pending_output_bytes - self.pending_output_bytes) return error.OutputTooSmall;
        const encoded = try self.allocator.alloc(u8, frame_len);
        errdefer self.allocator.free(encoded);
        _ = try protocol.encode_http3_control_frame(self.config.codec, frame, encoded);
        try self.outbound.append(self.allocator, .{ .stream_id = stream_id, .bytes = encoded });
        self.pending_output_bytes += encoded.len;
    }

    fn dropEntry(self: *Http3RequestStreamAdapter, index: usize) void {
        var entry = self.entries.orderedRemove(index);
        entry.deinit(self.allocator);
    }
};

const HeaderCollector = struct {
    allocator: std.mem.Allocator,
    maximum_header_bytes: usize,
    entry: *Entry,
    total_bytes: usize = 0,
    method_seen: bool = false,
    path_seen: bool = false,
    scheme_seen: bool = false,
    authority_seen: bool = false,
    credentials_seen: bool = false,
    regular_headers: bool = false,
    failure: ?Http3RequestStreamError = null,

    fn callback(context: ?*anyopaque, name_ptr: [*]const u8, name_len: usize, value_ptr: [*]const u8, value_len: usize) callconv(.c) c_int {
        const self: *@This() = @ptrCast(@alignCast(context orelse return 1));
        self.consume(name_ptr[0..name_len], value_ptr[0..value_len]) catch |err| {
            self.failure = err;
            return 1;
        };
        return 0;
    }

    fn consume(self: *HeaderCollector, name: []const u8, value: []const u8) Http3RequestStreamError!void {
        if (name.len == 0 or hasForbiddenByte(name) or hasForbiddenByte(value)) return error.RequestMalformed;
        const next = std.math.add(usize, self.total_bytes, std.math.add(usize, name.len, value.len) catch return error.RequestHeaderTooLarge) catch return error.RequestHeaderTooLarge;
        if (next > self.maximum_header_bytes) return error.RequestHeaderTooLarge;
        self.total_bytes = next;
        if (name[0] == ':') {
            if (self.regular_headers) return error.RequestMalformed;
            if (std.mem.eql(u8, name, ":method")) {
                if (self.method_seen or !isMethod(value)) return error.RequestMalformed;
                self.method_seen = true;
            } else if (std.mem.eql(u8, name, ":path")) {
                if (self.path_seen or value.len == 0 or value[0] != '/') return error.RequestMalformed;
                self.path_seen = true;
                try self.entry.path.appendSlice(self.allocator, value);
            } else if (std.mem.eql(u8, name, ":scheme")) {
                if (self.scheme_seen or value.len == 0) return error.RequestMalformed;
                self.scheme_seen = true;
            } else if (std.mem.eql(u8, name, ":authority")) {
                if (self.authority_seen or value.len == 0) return error.RequestMalformed;
                self.authority_seen = true;
            } else return error.RequestMalformed;
            return;
        }
        self.regular_headers = true;
        if (hasUppercase(name) or isConnectionHeader(name)) return error.RequestMalformed;
        if (std.mem.eql(u8, name, "authorization")) {
            if (self.credentials_seen) return error.RequestMalformed;
            self.credentials_seen = true;
            try self.entry.credentials.appendSlice(self.allocator, value);
        }
    }

    fn validate(self: *const HeaderCollector) Http3RequestStreamError!void {
        if (!self.method_seen or !self.path_seen or !self.scheme_seen or !self.authority_seen) return error.RequestMalformed;
    }
};

fn compactInbound(entry: *Entry) Http3RequestStreamError!void {
    if (entry.inbound_offset == 0) return;
    const remaining = entry.inbound.items.len - entry.inbound_offset;
    std.mem.copyForwards(u8, entry.inbound.items[0..remaining], entry.inbound.items[entry.inbound_offset..]);
    entry.inbound.items.len = remaining;
    entry.inbound_offset = 0;
}

fn hasForbiddenByte(value: []const u8) bool {
    for (value) |byte| if (byte == 0 or byte == '\r' or byte == '\n') return true;
    return false;
}

fn hasUppercase(value: []const u8) bool {
    for (value) |byte| if (byte >= 'A' and byte <= 'Z') return true;
    return false;
}

fn isMethod(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-') return false;
    return true;
}

fn isConnectionHeader(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "connection") or std.ascii.eqlIgnoreCase(value, "keep-alive") or std.ascii.eqlIgnoreCase(value, "proxy-connection") or std.ascii.eqlIgnoreCase(value, "transfer-encoding") or std.ascii.eqlIgnoreCase(value, "upgrade");
}

test "a public handler serves equivalent HTTP2 and HTTP3 responses" {
    const ConnectionProvider = struct {
        callback_context: ?*anyopaque = null,
        callback_fn: ?@import("quic_connection_lifecycle.zig").QuicConnectionCallback = null,

        fn open(context: ?*anyopaque, _: u64, _: @import("quic_connection_lifecycle.zig").QuicConnectionRole, callback_context: ?*anyopaque, callback_fn: @import("quic_connection_lifecycle.zig").QuicConnectionCallback) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.callback_context = callback_context;
            self.callback_fn = callback_fn;
            return 0;
        }

        fn shutdown(_: ?*anyopaque, _: u64) callconv(.c) void {}

        fn connected(self: *@This(), connection_id: u64) c_int {
            const event = @import("quic_connection_lifecycle.zig").QuicConnectionProviderEvent{ .connection_id = connection_id, .kind = @intFromEnum(@import("quic_connection_lifecycle.zig").QuicConnectionEventKind.connected) };
            return self.callback_fn.?(self.callback_context, &event);
        }
    };
    const HeaderProvider = struct {
        decode_calls: usize = 0,
        response_calls: usize = 0,

        fn decode(context: ?*anyopaque, input: [*]const u8, input_len: usize, callback_context: ?*anyopaque, callback: Http3HeaderCallback) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (!std.mem.eql(u8, input[0..input_len], "qpack-request")) return 1;
            self.decode_calls += 1;
            if (callback(callback_context, ":method".ptr, ":method".len, "GET".ptr, "GET".len) != 0) return 1;
            if (callback(callback_context, ":scheme".ptr, ":scheme".len, "https".ptr, "https".len) != 0) return 1;
            if (callback(callback_context, ":authority".ptr, ":authority".len, "fixture.test".ptr, "fixture.test".len) != 0) return 1;
            return callback(callback_context, ":path".ptr, ":path".len, "/public".ptr, "/public".len);
        }

        fn encode(context: ?*anyopaque, status: u16, output: [*]u8, capacity: usize, written: *usize) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (status != 200 or capacity < "qpack-status-200".len) return 1;
            self.response_calls += 1;
            @memcpy(output[0.."qpack-status-200".len], "qpack-status-200");
            written.* = "qpack-status-200".len;
            return 0;
        }
    };
    const StreamProvider = struct {
        cancellations: usize = 0,

        fn cancel(context: ?*anyopaque, _: u64, _: u64) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.cancellations += 1;
        }
    };
    const Handler = struct {
        calls: usize = 0,

        fn route(context: ?*anyopaque, request: service.ServiceRequest) service.ServiceModuleError!service.ServiceRouteResult {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (!std.mem.eql(u8, request.route, "/public")) return error.CallbackFailed;
            self.calls += 1;
            return .handled;
        }
    };

    var handler = Handler{};
    var services = try service.ServiceRegistry.init(std.testing.allocator, .{ .maximum_modules = 1 });
    defer services.deinit();
    _ = try services.register(.{ .config = .{ .name = "public", .route_prefix = "/public", .maximum_state_bytes = 1 }, .context = &handler, .hooks = .{ .route = Handler.route } });
    try services.start();
    var http2_resources = try resource.ResourceRegistry.init(std.testing.allocator, 1);
    defer http2_resources.deinit();
    var http2 = try @import("http2_server_session.zig").Http2ServerSession.init(std.testing.allocator, .{ .services = &services, .resources = &http2_resources, .transport = .prior_knowledge, .maximum_streams = 1 });
    defer http2.deinit();
    const http2_request = @import("http2_server_session.zig").http2_client_preface ++ "\x00\x00\x00\x04\x00\x00\x00\x00\x00" ++ "\x00\x00\x25\x01\x05\x00\x00\x00\x01\x82\x86\x41\x8b\x08\x9d\x5c\x0b\x81\x70\xdc\x69\xb7\x9f\x0f\x04\x85\x62\xbb\x63\xa0\xc4\x7a\x88\x25\xb6\x50\xc3\xcb\xba\xb8\x7f\x53\x03\x2a\x2f\x2a";
    try std.testing.expectEqual(@as(u16, 200), (try http2.feed(http2_request)).response.?.status);

    var quic_resources = try resource.ResourceRegistry.init(std.testing.allocator, 1);
    defer quic_resources.deinit();
    var sessions = try @import("session_registry.zig").SessionRegistry.init(std.testing.allocator, &quic_resources, 1);
    defer sessions.deinit();
    var connection_provider = ConnectionProvider{};
    var lifecycle = try @import("quic_connection_lifecycle.zig").QuicConnectionLifecycle.init(std.testing.allocator, &sessions, .{}, &connection_provider, .{ .open = ConnectionProvider.open, .shutdown = ConnectionProvider.shutdown });
    defer lifecycle.deinit();
    const session_handle = try lifecycle.connect(.{ .role = .client }, 0);
    try std.testing.expectEqual(0, connection_provider.connected(try lifecycle.connectionId(session_handle)));
    _ = try lifecycle.poll(0, 1);
    var controls = try control.Http3ControlSession.init(std.testing.allocator, &lifecycle, session_handle, .{});
    defer controls.deinit();
    try controls.acceptPeerControlStream(2);
    _ = try controls.feed(2, "\x04\x02\x06\x00");
    var header_provider = HeaderProvider{};
    var stream_provider = StreamProvider{};
    var adapter = try Http3RequestStreamAdapter.init(std.testing.allocator, &controls, .{ .services = &services }, &header_provider, .{ .decode_request = HeaderProvider.decode, .encode_response = HeaderProvider.encode }, &stream_provider, .{ .cancel = StreamProvider.cancel });
    defer adapter.deinit();
    _ = try adapter.feed(0, "\x01\x0d" ++ "qpack-request");
    const response = try adapter.finish(0);
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqual(@as(usize, 2), handler.calls);
    try std.testing.expectEqual(@as(usize, 1), header_provider.decode_calls);
    try std.testing.expectEqual(@as(usize, 1), header_provider.response_calls);
    var short_output: [1]u8 = undefined;
    try std.testing.expectError(error.OutputTooSmall, adapter.drainResponse(short_output[0..]));
    var output: [64]u8 = undefined;
    const write = (try adapter.drainResponse(output[0..])).?;
    try std.testing.expectEqual(@as(u64, 0), write.stream_id);
    try std.testing.expect(write.end_stream);
    const frame = try protocol.decode_http3_control_frame(.{}, write.bytes);
    try std.testing.expectEqual(@as(u64, @intFromEnum(protocol.Http3FrameType.headers)), frame.frame.frame_type);
    try std.testing.expectEqualStrings("qpack-status-200", frame.frame.payload);
}

test "HTTP3 request streams cancel through their provider" {
    const HeaderProvider = struct {
        fn decode(_: ?*anyopaque, _: [*]const u8, _: usize, _: ?*anyopaque, _: Http3HeaderCallback) callconv(.c) c_int {
            return 1;
        }

        fn encode(_: ?*anyopaque, _: u16, _: [*]u8, _: usize, _: *usize) callconv(.c) c_int {
            return 1;
        }
    };
    const StreamProvider = struct {
        cancellations: usize = 0,

        fn cancel(context: ?*anyopaque, _: u64, error_code: u64) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.cancellations += 1;
            std.debug.assert(error_code == @intFromEnum(control.Http3ErrorCode.request_cancelled));
        }
    };
    const ConnectionProvider = struct {
        callback_context: ?*anyopaque = null,
        callback_fn: ?@import("quic_connection_lifecycle.zig").QuicConnectionCallback = null,

        fn open(context: ?*anyopaque, _: u64, _: @import("quic_connection_lifecycle.zig").QuicConnectionRole, callback_context: ?*anyopaque, callback_fn: @import("quic_connection_lifecycle.zig").QuicConnectionCallback) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.callback_context = callback_context;
            self.callback_fn = callback_fn;
            return 0;
        }

        fn shutdown(_: ?*anyopaque, _: u64) callconv(.c) void {}

        fn connected(self: *@This(), connection_id: u64) c_int {
            const event = @import("quic_connection_lifecycle.zig").QuicConnectionProviderEvent{ .connection_id = connection_id, .kind = @intFromEnum(@import("quic_connection_lifecycle.zig").QuicConnectionEventKind.connected) };
            return self.callback_fn.?(self.callback_context, &event);
        }
    };

    var resources = try resource.ResourceRegistry.init(std.testing.allocator, 1);
    defer resources.deinit();
    var sessions = try @import("session_registry.zig").SessionRegistry.init(std.testing.allocator, &resources, 1);
    defer sessions.deinit();
    var connection_provider = ConnectionProvider{};
    var lifecycle = try @import("quic_connection_lifecycle.zig").QuicConnectionLifecycle.init(std.testing.allocator, &sessions, .{}, &connection_provider, .{ .open = ConnectionProvider.open, .shutdown = ConnectionProvider.shutdown });
    defer lifecycle.deinit();
    const session_handle = try lifecycle.connect(.{ .role = .client }, 0);
    try std.testing.expectEqual(0, connection_provider.connected(try lifecycle.connectionId(session_handle)));
    _ = try lifecycle.poll(0, 1);
    var controls = try control.Http3ControlSession.init(std.testing.allocator, &lifecycle, session_handle, .{});
    defer controls.deinit();
    try controls.acceptPeerControlStream(2);
    _ = try controls.feed(2, "\x04\x00");
    var services = try service.ServiceRegistry.init(std.testing.allocator, .{ .maximum_modules = 0 });
    defer services.deinit();
    try services.start();
    var stream_provider = StreamProvider{};
    var adapter = try Http3RequestStreamAdapter.init(std.testing.allocator, &controls, .{ .services = &services }, null, .{ .decode_request = HeaderProvider.decode, .encode_response = HeaderProvider.encode }, &stream_provider, .{ .cancel = StreamProvider.cancel });
    defer adapter.deinit();
    _ = try adapter.feed(4, &.{});
    try adapter.cancel(4, .request_cancelled);
    try std.testing.expectEqual(@as(usize, 1), stream_provider.cancellations);
    try std.testing.expectError(error.UnknownStream, adapter.status(4));
}
