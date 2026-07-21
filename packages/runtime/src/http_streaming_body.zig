const std = @import("std");
const protocol = @import("minna-san-protocol");

pub const max_http_body_stream_buffer_bytes: usize = 64 * 1024;
pub const HttpBodyStreamError = std.mem.Allocator.Error || protocol.HttpParserError || error{ InvalidConfiguration, InvalidState, BufferFull, WritePending, ChunkTooLarge, BodyTooLarge, Cancelled };
pub const HttpBodyStreamState = enum { open, finishing, complete, cancelled };
pub const HttpBodyBackpressure = enum { writable, blocked, closed };
pub const HttpBodyOffer = struct { accepted: usize, backpressure: HttpBodyBackpressure };
pub const HttpBodyRead = struct { bytes_read: usize, complete: bool };
pub const HttpBodyWrite = struct { accepted: usize, pending_bytes: usize, backpressure: HttpBodyBackpressure };

pub const HttpBodyReaderConfig = struct {
    maximum_buffer_bytes: usize,

    pub fn validate(self: HttpBodyReaderConfig) HttpBodyStreamError!void {
        if (self.maximum_buffer_bytes == 0 or self.maximum_buffer_bytes > max_http_body_stream_buffer_bytes) return error.InvalidConfiguration;
    }
};

pub const HttpBodyReader = struct {
    allocator: std.mem.Allocator,
    storage: []u8,
    head: usize = 0,
    length: usize = 0,
    state: HttpBodyStreamState = .open,

    pub fn init(allocator: std.mem.Allocator, config: HttpBodyReaderConfig) HttpBodyStreamError!HttpBodyReader {
        try config.validate();
        return .{ .allocator = allocator, .storage = try allocator.alloc(u8, config.maximum_buffer_bytes) };
    }

    pub fn deinit(self: *HttpBodyReader) void {
        self.allocator.free(self.storage);
        self.* = undefined;
    }

    pub fn available(self: *const HttpBodyReader) usize {
        return self.storage.len - self.length;
    }

    pub fn offer(self: *HttpBodyReader, input: []const u8) HttpBodyStreamError!HttpBodyOffer {
        if (self.state == .cancelled) return error.Cancelled;
        if (self.state != .open) return error.InvalidState;
        const accepted = @min(input.len, self.available());
        if (accepted != 0) self.copyIn(input[0..accepted]);
        return .{ .accepted = accepted, .backpressure = self.backpressure() };
    }

    pub fn read(self: *HttpBodyReader, output: []u8) HttpBodyStreamError!HttpBodyRead {
        if (self.state == .cancelled) return error.Cancelled;
        if (output.len == 0) return error.InvalidConfiguration;
        const count = @min(output.len, self.length);
        if (count != 0) self.copyOut(output[0..count]);
        self.length -= count;
        if (self.length == 0 and self.state == .finishing) self.state = .complete;
        return .{ .bytes_read = count, .complete = self.state == .complete };
    }

    pub fn finish(self: *HttpBodyReader) HttpBodyStreamError!void {
        if (self.state == .cancelled) return error.Cancelled;
        if (self.state != .open) return error.InvalidState;
        self.state = if (self.length == 0) .complete else .finishing;
    }

    pub fn cancel(self: *HttpBodyReader) void {
        self.length = 0;
        self.state = .cancelled;
    }

    pub fn backpressure(self: *const HttpBodyReader) HttpBodyBackpressure {
        return switch (self.state) {
            .open => if (self.available() == 0) .blocked else .writable,
            .finishing, .complete, .cancelled => .closed,
        };
    }

    fn copyIn(self: *HttpBodyReader, input: []const u8) void {
        const tail = (self.head + self.length) % self.storage.len;
        const first = @min(input.len, self.storage.len - tail);
        @memcpy(self.storage[tail .. tail + first], input[0..first]);
        @memcpy(self.storage[0 .. input.len - first], input[first..]);
        self.length += input.len;
    }

    fn copyOut(self: *HttpBodyReader, output: []u8) void {
        const first = @min(output.len, self.storage.len - self.head);
        @memcpy(output[0..first], self.storage[self.head .. self.head + first]);
        @memcpy(output[first..], self.storage[0 .. output.len - first]);
        self.head = (self.head + output.len) % self.storage.len;
    }
};

pub const HttpBodyWriterConfig = struct {
    maximum_buffer_bytes: usize,
    maximum_body_bytes: usize = protocol.max_http_body_bytes,

    pub fn validate(self: HttpBodyWriterConfig) HttpBodyStreamError!void {
        if (self.maximum_buffer_bytes < 6 or self.maximum_buffer_bytes > max_http_body_stream_buffer_bytes or self.maximum_body_bytes > protocol.max_http_body_bytes) return error.InvalidConfiguration;
    }
};

pub const HttpBodyWriter = struct {
    allocator: std.mem.Allocator,
    maximum_body_bytes: usize,
    storage: []u8,
    pending_offset: usize = 0,
    pending_length: usize = 0,
    body_bytes: usize = 0,
    state: HttpBodyStreamState = .open,

    pub fn init(allocator: std.mem.Allocator, config: HttpBodyWriterConfig) HttpBodyStreamError!HttpBodyWriter {
        try config.validate();
        return .{ .allocator = allocator, .maximum_body_bytes = config.maximum_body_bytes, .storage = try allocator.alloc(u8, config.maximum_buffer_bytes) };
    }

    pub fn deinit(self: *HttpBodyWriter) void {
        self.allocator.free(self.storage);
        self.* = undefined;
    }

    pub fn write(self: *HttpBodyWriter, body: []const u8) HttpBodyStreamError!HttpBodyWrite {
        if (self.state == .cancelled) return error.Cancelled;
        if (self.state != .open) return error.InvalidState;
        if (self.pending_length != 0) return error.WritePending;
        if (body.len == 0) return .{ .accepted = 0, .pending_bytes = 0, .backpressure = .writable };
        if (body.len > self.maximum_body_bytes - self.body_bytes) return error.BodyTooLarge;
        var length: [20]u8 = undefined;
        const encoded_length = std.fmt.bufPrint(&length, "{x}", .{body.len}) catch unreachable;
        const total = std.math.add(usize, encoded_length.len, body.len) catch return error.ChunkTooLarge;
        const framed = std.math.add(usize, total, 4) catch return error.ChunkTooLarge;
        if (framed > self.storage.len) return error.ChunkTooLarge;
        @memcpy(self.storage[0..encoded_length.len], encoded_length);
        @memcpy(self.storage[encoded_length.len .. encoded_length.len + 2], "\r\n");
        @memcpy(self.storage[encoded_length.len + 2 .. encoded_length.len + 2 + body.len], body);
        @memcpy(self.storage[framed - 2 .. framed], "\r\n");
        self.pending_offset = 0;
        self.pending_length = framed;
        self.body_bytes += body.len;
        return .{ .accepted = body.len, .pending_bytes = framed, .backpressure = .blocked };
    }

    pub fn finish(self: *HttpBodyWriter) HttpBodyStreamError!HttpBodyWrite {
        if (self.state == .cancelled) return error.Cancelled;
        if (self.state != .open) return error.InvalidState;
        if (self.pending_length != 0) return error.WritePending;
        @memcpy(self.storage[0..5], "0\r\n\r\n");
        self.pending_offset = 0;
        self.pending_length = 5;
        self.state = .finishing;
        return .{ .accepted = 0, .pending_bytes = self.pending_length, .backpressure = .blocked };
    }

    pub fn pending(self: *const HttpBodyWriter) ?[]const u8 {
        if (self.pending_length == 0) return null;
        return self.storage[self.pending_offset .. self.pending_offset + self.pending_length];
    }

    pub fn consumeWritten(self: *HttpBodyWriter, count: usize) HttpBodyStreamError!HttpBodyBackpressure {
        if (self.state == .cancelled) return error.Cancelled;
        if (count == 0 or count > self.pending_length) return error.InvalidState;
        self.pending_offset += count;
        self.pending_length -= count;
        if (self.pending_length == 0) {
            self.pending_offset = 0;
            if (self.state == .finishing) self.state = .complete;
        }
        return self.backpressure();
    }

    pub fn cancel(self: *HttpBodyWriter) void {
        self.pending_offset = 0;
        self.pending_length = 0;
        self.state = .cancelled;
    }

    pub fn backpressure(self: *const HttpBodyWriter) HttpBodyBackpressure {
        return switch (self.state) {
            .open => if (self.pending_length == 0) .writable else .blocked,
            .finishing, .complete, .cancelled => .closed,
        };
    }
};

pub const HttpStreamingSessionEvent = union(enum) { parsing: protocol.HttpParserEvent, body_available: HttpBodyOffer, backpressured: void, complete: void };
pub const HttpStreamingSessionConfig = struct {
    parser: protocol.HttpParserConfig,
    maximum_buffer_bytes: usize,

    pub fn validate(self: HttpStreamingSessionConfig) HttpBodyStreamError!void {
        try self.parser.validate();
        try (HttpBodyReaderConfig{ .maximum_buffer_bytes = self.maximum_buffer_bytes }).validate();
    }
};

pub const HttpStreamingSession = struct {
    parser: protocol.HttpParser,
    reader: HttpBodyReader,
    state: HttpBodyStreamState = .open,

    pub fn init(allocator: std.mem.Allocator, config: HttpStreamingSessionConfig) HttpBodyStreamError!HttpStreamingSession {
        try config.validate();
        return .{ .parser = try protocol.HttpParser.init(config.parser), .reader = try HttpBodyReader.init(allocator, .{ .maximum_buffer_bytes = config.maximum_buffer_bytes }) };
    }

    pub fn deinit(self: *HttpStreamingSession) void {
        self.reader.deinit();
        self.* = undefined;
    }

    pub fn feed(self: *HttpStreamingSession, input: []const u8) HttpBodyStreamError!struct { consumed: usize, event: ?HttpStreamingSessionEvent } {
        if (self.state == .cancelled) return error.Cancelled;
        if (self.state != .open) return error.InvalidState;
        if (input.len != 0 and self.reader.available() == 0) return .{ .consumed = 0, .event = .{ .backpressured = {} } };
        const bounded = if (input.len == 0) input else input[0..@min(input.len, self.reader.available())];
        const parsed = try self.parser.feed(bounded);
        const parser_event = parsed.event orelse return .{ .consumed = parsed.consumed, .event = null };
        return switch (parser_event) {
            .body => |body| blk: {
                const offer = try self.reader.offer(body);
                if (offer.accepted != body.len) unreachable;
                break :blk .{ .consumed = parsed.consumed, .event = .{ .body_available = offer } };
            },
            .complete => blk: {
                try self.reader.finish();
                self.state = .complete;
                break :blk .{ .consumed = parsed.consumed, .event = .{ .complete = {} } };
            },
            else => .{ .consumed = parsed.consumed, .event = .{ .parsing = parser_event } },
        };
    }

    pub fn cancel(self: *HttpStreamingSession) void {
        if (self.state == .cancelled) return;
        self.reader.cancel();
        self.state = .cancelled;
    }
};

test "HTTP streaming sessions echo large chunked bodies through fixed buffers" {
    const payload = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    var session = try HttpStreamingSession.init(std.testing.allocator, .{ .parser = .{ .kind = .request, .maximum_body_bytes = payload.len }, .maximum_buffer_bytes = 8 });
    defer session.deinit();
    var writer = try HttpBodyWriter.init(std.testing.allocator, .{ .maximum_buffer_bytes = 16, .maximum_body_bytes = payload.len });
    defer writer.deinit();
    const request = "POST /echo HTTP/1.1\r\nHost: fixture.test\r\nContent-Length: 64\r\n\r\n";
    var offset: usize = 0;
    while (offset < request.len) {
        const result = try session.feed(request[offset..]);
        offset += result.consumed;
    }
    var output: [256]u8 = undefined;
    var output_len: usize = 0;
    offset = 0;
    while (offset < payload.len) {
        const result = try session.feed(payload[offset..]);
        offset += result.consumed;
        if (result.event) |event| if (event == .body_available) {
            var chunk: [8]u8 = undefined;
            const read = try session.reader.read(chunk[0..]);
            try std.testing.expectEqual(event.body_available.accepted, read.bytes_read);
            _ = try writer.write(chunk[0..read.bytes_read]);
            const pending = writer.pending().?;
            @memcpy(output[output_len .. output_len + pending.len], pending);
            output_len += pending.len;
            try std.testing.expectEqual(HttpBodyBackpressure.writable, try writer.consumeWritten(pending.len));
        };
    }
    const complete = try session.feed(&.{});
    try std.testing.expect(complete.event.? == .complete);
    _ = try writer.finish();
    const final = writer.pending().?;
    @memcpy(output[output_len .. output_len + final.len], final);
    output_len += final.len;
    try std.testing.expectEqual(HttpBodyBackpressure.closed, try writer.consumeWritten(final.len));
    try std.testing.expectEqualStrings("8\r\n01234567\r\n8\r\n89abcdef\r\n8\r\n01234567\r\n8\r\n89abcdef\r\n8\r\n01234567\r\n8\r\n89abcdef\r\n8\r\n01234567\r\n8\r\n89abcdef\r\n0\r\n\r\n", output[0..output_len]);
    try std.testing.expectEqual(@as(usize, 8), session.reader.storage.len);
    try std.testing.expectEqual(@as(usize, 16), writer.storage.len);
}

test "HTTP body handles signal backpressure and cancellation without retaining overflow" {
    var reader = try HttpBodyReader.init(std.testing.allocator, .{ .maximum_buffer_bytes = 4 });
    defer reader.deinit();
    try std.testing.expectEqual(@as(usize, 4), (try reader.offer("abcd")).accepted);
    const blocked = try reader.offer("e");
    try std.testing.expectEqual(@as(usize, 0), blocked.accepted);
    try std.testing.expectEqual(HttpBodyBackpressure.blocked, blocked.backpressure);
    var output: [2]u8 = undefined;
    _ = try reader.read(output[0..]);
    try std.testing.expectEqualStrings("ab", output[0..]);
    try std.testing.expectEqual(@as(usize, 1), (try reader.offer("e")).accepted);
    reader.cancel();
    try std.testing.expectError(error.Cancelled, reader.read(output[0..]));
}
