const std = @import("std");
const protocol = @import("minna-san-protocol");
const resource = @import("resource_handle.zig");
const connections = @import("quic_connection_lifecycle.zig");

pub const max_http3_control_pending_bytes: usize = protocol.max_http3_control_frame_bytes;

pub const Http3ErrorCode = enum(u64) {
    no_error = 0x0100,
    stream_creation_error = 0x0103,
    closed_critical_stream = 0x0104,
    frame_unexpected = 0x0105,
    frame_error = 0x0106,
    excessive_load = 0x0107,
    settings_error = 0x0109,
    missing_settings = 0x010a,
};

pub const Http3ControlSessionState = enum(u8) {
    awaiting_peer_control_stream,
    awaiting_settings,
    open,
    terminated,
};

pub const Http3ControlSessionConfig = struct {
    codec: protocol.Http3ControlCodecConfig = .{},
    local_settings: []const protocol.Http3Setting = &.{},
    maximum_pending_input_bytes: usize = max_http3_control_pending_bytes,
    maximum_pending_output_bytes: usize = max_http3_control_pending_bytes,

    pub fn validate(self: Http3ControlSessionConfig) Http3ControlSessionError!void {
        try self.codec.validate();
        try protocol.validate_http3_settings(self.codec, self.local_settings);
        if (self.maximum_pending_input_bytes < self.codec.maximum_frame_bytes or self.maximum_pending_input_bytes > max_http3_control_pending_bytes or self.maximum_pending_output_bytes == 0 or self.maximum_pending_output_bytes > max_http3_control_pending_bytes) return error.InvalidConfiguration;
    }
};

pub const Http3ControlSessionStatus = struct {
    session: *resource.ResourceHandle,
    state: Http3ControlSessionState,
    peer_control_stream: ?u64,
    peer_settings: []const protocol.Http3Setting,
    terminal_error: ?Http3ErrorCode,
};

pub const Http3ControlSessionError = std.mem.Allocator.Error || protocol.Http3ControlCodecError || resource.HandleError || connections.QuicConnectionLifecycleError || error{ InvalidConfiguration, InvalidState, ControlStreamNotAccepted, UnknownControlStream, DuplicateControlStream, UnexpectedFrame, CriticalStreamClosed, InputLimitExceeded, OutputTooSmall };

pub const Http3ControlSession = struct {
    allocator: std.mem.Allocator,
    config: Http3ControlSessionConfig,
    connections: *connections.QuicConnectionLifecycle,
    session_handle: *resource.ResourceHandle,
    peer_control_stream: ?u64 = null,
    received_settings: bool = false,
    state: Http3ControlSessionState = .awaiting_peer_control_stream,
    terminal_error: ?Http3ErrorCode = null,
    peer_settings: []protocol.Http3Setting,
    peer_settings_count: usize = 0,
    inbound: std.ArrayListUnmanaged(u8) = .empty,
    inbound_offset: usize = 0,
    outbound: std.ArrayListUnmanaged(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, lifecycle: *connections.QuicConnectionLifecycle, session_handle: *resource.ResourceHandle, config: Http3ControlSessionConfig) Http3ControlSessionError!Http3ControlSession {
        try config.validate();
        if ((try lifecycle.status(session_handle)).state != .ready) return error.InvalidState;
        const peer_settings = try allocator.alloc(protocol.Http3Setting, config.codec.maximum_settings);
        errdefer allocator.free(peer_settings);
        var result = Http3ControlSession{ .allocator = allocator, .config = config, .connections = lifecycle, .session_handle = session_handle, .peer_settings = peer_settings };
        errdefer result.outbound.deinit(allocator);
        try result.queueLocalControlStream();
        return result;
    }

    pub fn deinit(self: *Http3ControlSession) void {
        self.allocator.free(self.peer_settings);
        self.inbound.deinit(self.allocator);
        self.outbound.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn acceptPeerControlStream(self: *Http3ControlSession, stream_id: u64) Http3ControlSessionError!void {
        if (self.state != .awaiting_peer_control_stream) return error.InvalidState;
        self.peer_control_stream = stream_id;
        self.state = .awaiting_settings;
    }

    pub fn rejectAdditionalControlStream(self: *Http3ControlSession, stream_id: u64) Http3ControlSessionError!void {
        if (self.peer_control_stream == null or self.peer_control_stream.? == stream_id) return error.UnknownControlStream;
        try self.terminate(.stream_creation_error);
        return error.DuplicateControlStream;
    }

    pub fn feed(self: *Http3ControlSession, stream_id: u64, input: []const u8) Http3ControlSessionError!usize {
        if (self.state == .terminated) return error.InvalidState;
        if (self.peer_control_stream == null) return error.ControlStreamNotAccepted;
        if (self.peer_control_stream.? != stream_id) return error.UnknownControlStream;
        try self.compactInbound();
        if (input.len > self.config.maximum_pending_input_bytes - self.inbound.items.len) {
            try self.terminate(.excessive_load);
            return error.InputLimitExceeded;
        }
        try self.inbound.appendSlice(self.allocator, input);
        while (self.inbound_offset < self.inbound.items.len) {
            const decoded = protocol.decode_http3_control_frame(self.config.codec, self.inbound.items[self.inbound_offset..]) catch |err| switch (err) {
                error.IncompleteFrame => break,
                error.FrameTooLarge => {
                    try self.terminate(.excessive_load);
                    return err;
                },
                else => {
                    try self.terminate(.frame_error);
                    return err;
                },
            };
            try self.handleFrame(decoded.frame);
            self.inbound_offset += decoded.consumed;
        }
        try self.compactInbound();
        return input.len;
    }

    pub fn peerControlStreamClosed(self: *Http3ControlSession, stream_id: u64) Http3ControlSessionError!void {
        if (self.peer_control_stream == null or self.peer_control_stream.? != stream_id) return error.UnknownControlStream;
        try self.terminate(.closed_critical_stream);
        return error.CriticalStreamClosed;
    }

    pub fn drain(self: *Http3ControlSession, output: []u8) Http3ControlSessionError![]const u8 {
        if (output.len < self.outbound.items.len) return error.OutputTooSmall;
        @memcpy(output[0..self.outbound.items.len], self.outbound.items);
        const written = output[0..self.outbound.items.len];
        self.outbound.clearRetainingCapacity();
        return written;
    }

    pub fn status(self: *const Http3ControlSession) Http3ControlSessionStatus {
        return .{
            .session = self.session_handle,
            .state = self.state,
            .peer_control_stream = self.peer_control_stream,
            .peer_settings = self.peer_settings[0..self.peer_settings_count],
            .terminal_error = self.terminal_error,
        };
    }

    fn queueLocalControlStream(self: *Http3ControlSession) Http3ControlSessionError!void {
        const settings_len = try protocol.http3_settings_encoded_len(self.config.codec, self.config.local_settings);
        const stream_type_len = try protocol.quic_varint_encoded_len(0);
        const total = std.math.add(usize, stream_type_len, settings_len) catch return error.OutputTooSmall;
        if (total > self.config.maximum_pending_output_bytes) return error.OutputTooSmall;
        var temporary = try self.allocator.alloc(u8, total);
        defer self.allocator.free(temporary);
        var offset: usize = 0;
        offset += (try protocol.encode_quic_varint(0, temporary[offset..])).len;
        const settings = try protocol.encode_http3_settings(self.config.codec, self.config.local_settings, temporary[offset..]);
        offset += settings.len;
        try self.outbound.appendSlice(self.allocator, temporary[0..offset]);
    }

    fn handleFrame(self: *Http3ControlSession, frame: protocol.Http3ControlFrame) Http3ControlSessionError!void {
        if (!self.received_settings) {
            if (frame.frame_type != @intFromEnum(protocol.Http3FrameType.settings)) {
                try self.terminate(.missing_settings);
                return error.UnexpectedFrame;
            }
            const settings = protocol.decode_http3_settings(self.config.codec, frame.payload, self.peer_settings) catch |err| {
                try self.terminate(.settings_error);
                return err;
            };
            self.peer_settings_count = settings.len;
            self.received_settings = true;
            self.state = .open;
            return;
        }
        switch (@as(protocol.Http3FrameType, @enumFromInt(frame.frame_type))) {
            .settings => {
                try self.terminate(.frame_unexpected);
                return error.UnexpectedFrame;
            },
            .data, .headers, .push_promise => {
                try self.terminate(.frame_unexpected);
                return error.UnexpectedFrame;
            },
            .cancel_push, .goaway, .max_push_id => validateSingleVarint(frame.payload) catch |err| {
                try self.terminate(.frame_error);
                return err;
            },
            else => {},
        }
    }

    fn compactInbound(self: *Http3ControlSession) Http3ControlSessionError!void {
        if (self.inbound_offset == 0) return;
        const remaining = self.inbound.items.len - self.inbound_offset;
        std.mem.copyForwards(u8, self.inbound.items[0..remaining], self.inbound.items[self.inbound_offset..]);
        self.inbound.items.len = remaining;
        self.inbound_offset = 0;
    }

    fn terminate(self: *Http3ControlSession, error_code: Http3ErrorCode) Http3ControlSessionError!void {
        if (self.state == .terminated) return;
        self.state = .terminated;
        self.terminal_error = error_code;
        try self.connections.close(self.session_handle);
    }
};

fn validateSingleVarint(payload: []const u8) protocol.Http3ControlCodecError!void {
    const value = try protocol.decode_quic_varint(payload);
    if (value.consumed != payload.len) return error.InvalidSettings;
}

test "invalid HTTP3 settings terminate only their bound QUIC session" {
    const ConnectionProvider = struct {
        callback_context: ?*anyopaque = null,
        callback_fn: ?connections.QuicConnectionCallback = null,

        fn open(context: ?*anyopaque, _: u64, _: connections.QuicConnectionRole, callback_context: ?*anyopaque, callback_fn: connections.QuicConnectionCallback) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.callback_context = callback_context;
            self.callback_fn = callback_fn;
            return 0;
        }

        fn shutdown(context: ?*anyopaque, connection_id: u64) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            const event = connections.QuicConnectionProviderEvent{ .connection_id = connection_id, .kind = @intFromEnum(connections.QuicConnectionEventKind.shutdown_complete) };
            _ = self.callback_fn.?(self.callback_context, &event);
        }

        fn emit(self: *@This(), connection_id: u64, kind: connections.QuicConnectionEventKind) c_int {
            const event = connections.QuicConnectionProviderEvent{ .connection_id = connection_id, .kind = @intFromEnum(kind) };
            return self.callback_fn.?(self.callback_context, &event);
        }
    };

    var resources = try resource.ResourceRegistry.init(std.testing.allocator, 2);
    defer resources.deinit();
    var sessions = try @import("session_registry.zig").SessionRegistry.init(std.testing.allocator, &resources, 2);
    defer sessions.deinit();
    var provider = ConnectionProvider{};
    var lifecycle = try connections.QuicConnectionLifecycle.init(std.testing.allocator, &sessions, .{ .maximum_connections = 2, .maximum_events = 4 }, &provider, .{ .open = ConnectionProvider.open, .shutdown = ConnectionProvider.shutdown });
    defer lifecycle.deinit();
    const invalid_handle = try lifecycle.connect(.{ .role = .client }, 0);
    const healthy_handle = try lifecycle.connect(.{ .role = .client }, 0);
    try std.testing.expectEqual(0, provider.emit(try lifecycle.connectionId(invalid_handle), .connected));
    try std.testing.expectEqual(0, provider.emit(try lifecycle.connectionId(healthy_handle), .connected));
    try std.testing.expectEqual(@as(usize, 2), try lifecycle.poll(0, 2));

    var invalid = try Http3ControlSession.init(std.testing.allocator, &lifecycle, invalid_handle, .{});
    defer invalid.deinit();
    var healthy = try Http3ControlSession.init(std.testing.allocator, &lifecycle, healthy_handle, .{});
    defer healthy.deinit();
    var local: [8]u8 = undefined;
    try std.testing.expectEqualStrings("\x00\x04\x00", try invalid.drain(local[0..]));
    try invalid.acceptPeerControlStream(2);
    try healthy.acceptPeerControlStream(6);
    _ = try healthy.feed(6, "\x04\x02\x06\x00");
    try std.testing.expectError(error.DuplicateSetting, invalid.feed(2, "\x04\x04\x06\x00\x06\x01"));
    try std.testing.expectEqual(Http3ErrorCode.settings_error, invalid.status().terminal_error.?);
    try std.testing.expectEqual(Http3ControlSessionState.open, healthy.status().state);
    try std.testing.expectEqual(@as(usize, 1), try lifecycle.poll(1, 1));
    try std.testing.expectError(error.StaleHandle, sessions.lookup(invalid_handle));
    try std.testing.expectEqual(@import("session_lifecycle.zig").SessionState.ready, (try lifecycle.status(healthy_handle)).state);
}

test "HTTP3 control sessions require one critical control stream and SETTINGS first" {
    const ConnectionProvider = struct {
        callback_context: ?*anyopaque = null,
        callback_fn: ?connections.QuicConnectionCallback = null,

        fn open(context: ?*anyopaque, _: u64, _: connections.QuicConnectionRole, callback_context: ?*anyopaque, callback_fn: connections.QuicConnectionCallback) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.callback_context = callback_context;
            self.callback_fn = callback_fn;
            return 0;
        }

        fn shutdown(_: ?*anyopaque, _: u64) callconv(.c) void {}

        fn emit(self: *@This(), connection_id: u64) c_int {
            const event = connections.QuicConnectionProviderEvent{ .connection_id = connection_id, .kind = @intFromEnum(connections.QuicConnectionEventKind.connected) };
            return self.callback_fn.?(self.callback_context, &event);
        }
    };

    var resources = try resource.ResourceRegistry.init(std.testing.allocator, 1);
    defer resources.deinit();
    var sessions = try @import("session_registry.zig").SessionRegistry.init(std.testing.allocator, &resources, 1);
    defer sessions.deinit();
    var provider = ConnectionProvider{};
    var lifecycle = try connections.QuicConnectionLifecycle.init(std.testing.allocator, &sessions, .{}, &provider, .{ .open = ConnectionProvider.open, .shutdown = ConnectionProvider.shutdown });
    defer lifecycle.deinit();
    const handle = try lifecycle.connect(.{ .role = .client }, 0);
    try std.testing.expectEqual(0, provider.emit(try lifecycle.connectionId(handle)));
    _ = try lifecycle.poll(0, 1);
    var control = try Http3ControlSession.init(std.testing.allocator, &lifecycle, handle, .{});
    defer control.deinit();
    try control.acceptPeerControlStream(2);
    try std.testing.expectError(error.UnexpectedFrame, control.feed(2, "\x07\x01\x00"));
    try std.testing.expectEqual(Http3ErrorCode.missing_settings, control.status().terminal_error.?);
}
