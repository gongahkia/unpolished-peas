const std = @import("std");
const resource = @import("resource_handle.zig");
const streams = @import("http2_stream_state.zig");

pub const max_http2_window: u32 = 0x7fffffff;
pub const Http2FlowControlError = std.mem.Allocator.Error || resource.HandleError || streams.Http2StreamError || error{ InvalidConfiguration, StreamCapacityExceeded, UnknownStream, InvalidWindowIncrement, WindowOverflow, BufferFull, WriteCompletionMismatch };
pub const Http2FlowBackpressure = enum { writable, connection_window, stream_window, buffer_full, closed };
pub const Http2FlowReservation = struct { accepted: usize, backpressure: Http2FlowBackpressure, connection_window: u32, stream_window: u32, buffered_bytes: usize };
pub const Http2FlowControlConfig = struct {
    stream_registry: *streams.Http2StreamRegistry,
    maximum_streams: usize,
    initial_connection_window: u32 = 65535,
    initial_stream_window: u32 = 65535,
    maximum_buffered_bytes_per_stream: usize,

    pub fn validate(self: Http2FlowControlConfig) Http2FlowControlError!void {
        if (self.maximum_streams == 0 or self.initial_connection_window == 0 or self.initial_connection_window > max_http2_window or self.initial_stream_window == 0 or self.initial_stream_window > max_http2_window or self.maximum_buffered_bytes_per_stream == 0) return error.InvalidConfiguration;
    }
};

const Entry = struct { stream: *resource.ResourceHandle, window: u32, buffered_bytes: usize = 0 };

pub const Http2FlowController = struct {
    allocator: std.mem.Allocator,
    streams: *streams.Http2StreamRegistry,
    capacity: usize,
    initial_stream_window: u32,
    maximum_buffered_bytes_per_stream: usize,
    connection_window: u32,
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator, config: Http2FlowControlConfig) Http2FlowControlError!Http2FlowController {
        try config.validate();
        return .{ .allocator = allocator, .streams = config.stream_registry, .capacity = config.maximum_streams, .initial_stream_window = config.initial_stream_window, .maximum_buffered_bytes_per_stream = config.maximum_buffered_bytes_per_stream, .connection_window = config.initial_connection_window };
    }

    pub fn deinit(self: *Http2FlowController) void {
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn attach(self: *Http2FlowController, stream: *resource.ResourceHandle) Http2FlowControlError!void {
        _ = try self.streams.snapshot(stream);
        if (self.entries.items.len == self.capacity) return error.StreamCapacityExceeded;
        for (self.entries.items) |entry| if (entry.stream == stream) return error.InvalidConfiguration;
        try self.entries.append(self.allocator, .{ .stream = stream, .window = self.initial_stream_window });
    }

    pub fn reserve(self: *Http2FlowController, stream: *resource.ResourceHandle, bytes: usize) Http2FlowControlError!Http2FlowReservation {
        const entry = try self.lookup(stream);
        const snapshot = try self.streams.snapshot(stream);
        if (snapshot.state == .closed) return self.reservation(entry, .closed, 0);
        if (bytes > self.maximum_buffered_bytes_per_stream - entry.buffered_bytes) return self.reservation(entry, .buffer_full, 0);
        if (self.connection_window == 0) return self.reservation(entry, .connection_window, 0);
        if (entry.window == 0) return self.reservation(entry, .stream_window, 0);
        const accepted = @min(bytes, @min(@as(usize, self.connection_window), @as(usize, entry.window)));
        if (accepted == 0) return self.reservation(entry, if (self.connection_window == 0) .connection_window else .stream_window, 0);
        self.connection_window -= @intCast(accepted);
        entry.window -= @intCast(accepted);
        entry.buffered_bytes += accepted;
        const backpressure: Http2FlowBackpressure = if (self.connection_window == 0)
            .connection_window
        else if (entry.window == 0)
            .stream_window
        else if (entry.buffered_bytes == self.maximum_buffered_bytes_per_stream)
            .buffer_full
        else
            .writable;
        return self.reservation(entry, backpressure, accepted);
    }

    pub fn completeWrite(self: *Http2FlowController, stream: *resource.ResourceHandle, bytes: usize) Http2FlowControlError!Http2FlowBackpressure {
        const entry = try self.lookup(stream);
        if (bytes > entry.buffered_bytes) return error.WriteCompletionMismatch;
        entry.buffered_bytes -= bytes;
        return self.reservation(entry, .writable, 0).backpressure;
    }

    pub fn receiveWindowUpdate(self: *Http2FlowController, stream: ?*resource.ResourceHandle, increment: u32) Http2FlowControlError!void {
        if (increment == 0 or increment > max_http2_window) return error.InvalidWindowIncrement;
        if (stream) |handle| {
            const entry = try self.lookup(handle);
            if (increment > max_http2_window - entry.window) return error.WindowOverflow;
            entry.window += increment;
        } else {
            if (increment > max_http2_window - self.connection_window) return error.WindowOverflow;
            self.connection_window += increment;
        }
    }

    pub fn applyInitialStreamWindow(self: *Http2FlowController, next: u32) Http2FlowControlError!void {
        if (next == 0 or next > max_http2_window) return error.InvalidConfiguration;
        for (self.entries.items) |*entry| {
            const adjusted = @as(i64, entry.window) + @as(i64, next) - @as(i64, self.initial_stream_window);
            if (adjusted < 0 or adjusted > max_http2_window) return error.WindowOverflow;
            entry.window = @intCast(adjusted);
        }
        self.initial_stream_window = next;
    }

    fn lookup(self: *Http2FlowController, stream: *resource.ResourceHandle) Http2FlowControlError!*Entry {
        for (self.entries.items) |*entry| if (entry.stream == stream) return entry;
        return error.UnknownStream;
    }

    fn reservation(self: *const Http2FlowController, entry: *const Entry, backpressure: Http2FlowBackpressure, accepted: usize) Http2FlowReservation {
        return .{ .accepted = accepted, .backpressure = backpressure, .connection_window = self.connection_window, .stream_window = entry.window, .buffered_bytes = entry.buffered_bytes };
    }
};

test "HTTP2 flow control isolates a stalled stream from separate writable streams" {
    var resources = try resource.ResourceRegistry.init(std.testing.allocator, 2);
    defer resources.deinit();
    var registry = try streams.Http2StreamRegistry.init(std.testing.allocator, &resources, .{ .role = .client, .maximum_streams = 2 });
    defer registry.deinit();
    const stalled = try registry.create(1, .open_local, .{});
    const writable = try registry.create(3, .open_local, .{});
    var flow = try Http2FlowController.init(std.testing.allocator, .{ .stream_registry = &registry, .maximum_streams = 2, .initial_connection_window = 24, .initial_stream_window = 8, .maximum_buffered_bytes_per_stream = 16 });
    defer flow.deinit();
    try flow.attach(stalled);
    try flow.attach(writable);
    try std.testing.expectEqual(Http2FlowBackpressure.stream_window, (try flow.reserve(stalled, 8)).backpressure);
    try std.testing.expectEqual(@as(usize, 8), (try flow.reserve(writable, 8)).accepted);
    try std.testing.expectEqual(@as(usize, 0), (try flow.reserve(stalled, 1)).accepted);
    try flow.receiveWindowUpdate(stalled, 8);
    try flow.applyInitialStreamWindow(4);
    _ = try flow.completeWrite(stalled, 8);
    try std.testing.expectEqual(@as(usize, 1), (try flow.reserve(stalled, 1)).accepted);
}
