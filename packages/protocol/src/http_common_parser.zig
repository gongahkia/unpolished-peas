const std = @import("std");

pub const max_http_start_line_bytes: usize = 8 * 1024;
pub const max_http_header_bytes: usize = 64 * 1024;
pub const max_http_headers: usize = 128;
pub const max_http_body_bytes: usize = 16 * 1024 * 1024;
pub const HttpParserError = error{ InvalidConfiguration, InvalidState, LineTooLong, HeaderTooLarge, HeaderCountExceeded, MalformedStartLine, MalformedHeader, InvalidToken, InvalidContentLength, ConflictingBodyFraming, UnsupportedTransferEncoding, BodyTooLarge, MalformedChunk, UnexpectedEnd };
pub const HttpMessageKind = enum { request, response };
pub const HttpBodyFraming = union(enum) { none, content_length: usize, chunked: void };
pub const HttpRequestLine = struct { method: []const u8, target: []const u8 };
pub const HttpStatusLine = struct { status: u16, reason: []const u8 };
pub const HttpHeader = struct { name: []const u8, value: []const u8 };
pub const HttpParserEvent = union(enum) { request_line: HttpRequestLine, status_line: HttpStatusLine, header: HttpHeader, headers_complete: HttpBodyFraming, body: []const u8, complete: void };
pub const HttpParserFeed = struct { consumed: usize, event: ?HttpParserEvent };
pub const HttpParserConfig = struct {
    kind: HttpMessageKind,
    maximum_start_line_bytes: usize = max_http_start_line_bytes,
    maximum_header_bytes: usize = max_http_header_bytes,
    maximum_headers: usize = max_http_headers,
    maximum_body_bytes: usize = max_http_body_bytes,

    pub fn validate(self: HttpParserConfig) HttpParserError!void {
        if (self.maximum_start_line_bytes == 0 or self.maximum_start_line_bytes > max_http_start_line_bytes or self.maximum_header_bytes == 0 or self.maximum_header_bytes > max_http_header_bytes or self.maximum_headers == 0 or self.maximum_headers > max_http_headers or self.maximum_body_bytes > max_http_body_bytes) return error.InvalidConfiguration;
    }
};

const State = enum { start_line, headers, fixed_body, chunk_size, chunk_body, chunk_crlf, trailers, complete, failed };

pub const HttpParser = struct {
    config: HttpParserConfig,
    storage: [max_http_header_bytes]u8 = undefined,
    line_len: usize = 0,
    header_bytes: usize = 0,
    header_count: usize = 0,
    content_length: ?usize = null,
    transfer_chunked: bool = false,
    body_remaining: usize = 0,
    body_received: usize = 0,
    state: State = .start_line,

    pub fn init(config: HttpParserConfig) HttpParserError!HttpParser {
        try config.validate();
        return .{ .config = config };
    }

    pub fn feed(self: *HttpParser, input: []const u8) HttpParserError!HttpParserFeed {
        if (self.state == .failed) return error.InvalidState;
        if (self.state == .complete) return .{ .consumed = 0, .event = .complete };
        return switch (self.state) {
            .start_line, .headers, .chunk_size, .trailers => self.feedLine(input),
            .fixed_body, .chunk_body => self.feedBody(input),
            .chunk_crlf => self.feedChunkCrlf(input),
            .complete, .failed => unreachable,
        };
    }

    pub fn reset(self: *HttpParser) void {
        const config = self.config;
        self.* = .{ .config = config };
    }

    fn feedLine(self: *HttpParser, input: []const u8) HttpParserError!HttpParserFeed {
        var consumed: usize = 0;
        while (consumed < input.len) : (consumed += 1) {
            const byte = input[consumed];
            if (byte == '\n') {
                if (self.line_len == 0 or self.storage[self.line_len - 1] != '\r') return self.fail(error.MalformedHeader);
                self.line_len -= 1;
                const line = self.storage[0..self.line_len];
                self.line_len = 0;
                return .{ .consumed = consumed + 1, .event = try self.consumeLine(line) };
            }
            try self.appendLineByte(byte);
        }
        return .{ .consumed = consumed, .event = null };
    }

    fn feedBody(self: *HttpParser, input: []const u8) HttpParserError!HttpParserFeed {
        if (input.len == 0) return .{ .consumed = 0, .event = null };
        const count = @min(input.len, self.body_remaining);
        const body = input[0..count];
        self.body_remaining -= count;
        if (self.body_remaining == 0) self.state = if (self.transfer_chunked) .chunk_crlf else .complete;
        return .{ .consumed = count, .event = .{ .body = body } };
    }

    fn feedChunkCrlf(self: *HttpParser, input: []const u8) HttpParserError!HttpParserFeed {
        if (input.len < 2) return .{ .consumed = 0, .event = null };
        if (!std.mem.eql(u8, input[0..2], "\r\n")) return self.fail(error.MalformedChunk);
        self.state = .chunk_size;
        return .{ .consumed = 2, .event = null };
    }

    fn consumeLine(self: *HttpParser, line: []const u8) HttpParserError!?HttpParserEvent {
        return switch (self.state) {
            .start_line => self.consumeStartLine(line),
            .headers => self.consumeHeader(line),
            .chunk_size => self.consumeChunkSize(line),
            .trailers => self.consumeTrailer(line),
            else => unreachable,
        };
    }

    fn consumeStartLine(self: *HttpParser, line: []const u8) HttpParserError!?HttpParserEvent {
        if (line.len > self.config.maximum_start_line_bytes) return self.fail(error.LineTooLong);
        self.state = .headers;
        return switch (self.config.kind) {
            .request => .{ .request_line = try parseRequestLine(line) },
            .response => .{ .status_line = try parseStatusLine(line) },
        };
    }

    fn consumeHeader(self: *HttpParser, line: []const u8) HttpParserError!?HttpParserEvent {
        if (line.len == 0) {
            const body_framing = try self.framing();
            switch (body_framing) {
                .none => self.state = .complete,
                .content_length => |length| {
                    self.body_remaining = length;
                    self.state = if (length == 0) .complete else .fixed_body;
                },
                .chunked => self.state = .chunk_size,
            }
            return .{ .headers_complete = body_framing };
        }
        self.header_count += 1;
        if (self.header_count > self.config.maximum_headers) return self.fail(error.HeaderCountExceeded);
        self.header_bytes = std.math.add(usize, self.header_bytes, line.len + 2) catch return self.fail(error.HeaderTooLarge);
        if (self.header_bytes > self.config.maximum_header_bytes) return self.fail(error.HeaderTooLarge);
        const header = try parseHeader(line);
        if (std.ascii.eqlIgnoreCase(header.name, "content-length")) try self.observeContentLength(header.value);
        if (std.ascii.eqlIgnoreCase(header.name, "transfer-encoding")) try self.observeTransferEncoding(header.value);
        return .{ .header = header };
    }

    fn consumeChunkSize(self: *HttpParser, line: []const u8) HttpParserError!?HttpParserEvent {
        const size = parseChunkSize(line) catch return self.fail(error.MalformedChunk);
        if (size > self.config.maximum_body_bytes - self.body_received) return self.fail(error.BodyTooLarge);
        if (size == 0) {
            self.state = .trailers;
            return null;
        }
        self.body_received += size;
        self.body_remaining = size;
        self.state = .chunk_body;
        return null;
    }

    fn consumeTrailer(self: *HttpParser, line: []const u8) HttpParserError!?HttpParserEvent {
        if (line.len != 0) return self.fail(error.MalformedChunk);
        self.state = .complete;
        return .complete;
    }

    fn framing(self: *HttpParser) HttpParserError!HttpBodyFraming {
        if (self.transfer_chunked and self.content_length != null) return self.fail(error.ConflictingBodyFraming);
        if (self.transfer_chunked) return .chunked;
        if (self.content_length) |length| {
            if (length > self.config.maximum_body_bytes) return self.fail(error.BodyTooLarge);
            return .{ .content_length = length };
        }
        return .none;
    }

    fn observeContentLength(self: *HttpParser, value: []const u8) HttpParserError!void {
        const length = std.fmt.parseUnsigned(usize, trimOws(value), 10) catch return self.fail(error.InvalidContentLength);
        if (self.content_length) |existing| if (existing != length) return self.fail(error.ConflictingBodyFraming);
        self.content_length = length;
    }

    fn observeTransferEncoding(self: *HttpParser, value: []const u8) HttpParserError!void {
        if (!std.ascii.eqlIgnoreCase(trimOws(value), "chunked") or self.transfer_chunked) return self.fail(error.UnsupportedTransferEncoding);
        self.transfer_chunked = true;
    }

    fn appendLineByte(self: *HttpParser, byte: u8) HttpParserError!void {
        if (byte == '\r' and self.line_len + 1 > self.config.maximum_start_line_bytes and self.state == .start_line) return self.fail(error.LineTooLong);
        if (self.line_len == self.config.maximum_header_bytes) return self.fail(error.HeaderTooLarge);
        self.storage[self.line_len] = byte;
        self.line_len += 1;
    }

    fn fail(self: *HttpParser, err: HttpParserError) HttpParserError {
        self.state = .failed;
        return err;
    }
};

fn parseRequestLine(line: []const u8) HttpParserError!HttpRequestLine {
    const first = std.mem.indexOfScalar(u8, line, ' ') orelse return error.MalformedStartLine;
    const second_relative = std.mem.indexOfScalar(u8, line[first + 1 ..], ' ') orelse return error.MalformedStartLine;
    const second = first + 1 + second_relative;
    const method = line[0..first];
    const target = line[first + 1 .. second];
    if (method.len == 0 or target.len == 0 or !std.mem.eql(u8, line[second + 1 ..], "HTTP/1.1")) return error.MalformedStartLine;
    for (method) |byte| if (!isToken(byte)) return error.InvalidToken;
    return .{ .method = method, .target = target };
}

fn parseStatusLine(line: []const u8) HttpParserError!HttpStatusLine {
    if (line.len < 13 or !std.mem.startsWith(u8, line, "HTTP/1.1 ") or line[12] != ' ') return error.MalformedStartLine;
    const status = std.fmt.parseUnsigned(u16, line[9..12], 10) catch return error.MalformedStartLine;
    if (status < 100) return error.MalformedStartLine;
    return .{ .status = status, .reason = line[13..] };
}

fn parseHeader(line: []const u8) HttpParserError!HttpHeader {
    const separator = std.mem.indexOfScalar(u8, line, ':') orelse return error.MalformedHeader;
    const name = line[0..separator];
    if (name.len == 0) return error.MalformedHeader;
    for (name) |byte| if (!isToken(byte)) return error.InvalidToken;
    return .{ .name = name, .value = trimOws(line[separator + 1 ..]) };
}

fn parseChunkSize(line: []const u8) !usize {
    if (line.len == 0 or std.mem.indexOfScalar(u8, line, ';') != null) return error.MalformedChunk;
    return std.fmt.parseUnsigned(usize, line, 16);
}

fn trimOws(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t");
}

fn isToken(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", byte) != null;
}

test "incremental HTTP parser bounds malformed headers and decodes fixed and chunked body framing" {
    var parser = try HttpParser.init(.{ .kind = .request, .maximum_start_line_bytes = 32, .maximum_header_bytes = 64, .maximum_headers = 2, .maximum_body_bytes = 8 });
    const first = try parser.feed("GET / HTTP/1.1\r");
    try std.testing.expect(first.event == null);
    const lines = "\nContent-Length: 3\r\n\r\nabc";
    const request = try parser.feed(lines);
    try std.testing.expectEqualStrings("GET", request.event.?.request_line.method);
    const header = try parser.feed(lines[request.consumed..]);
    try std.testing.expectEqualStrings("3", header.event.?.header.value);
    const complete = try parser.feed(lines[request.consumed + header.consumed ..]);
    try std.testing.expectEqual(@as(usize, 3), complete.event.?.headers_complete.content_length);
    const body = try parser.feed(lines[request.consumed + header.consumed + complete.consumed ..]);
    try std.testing.expectEqualStrings("abc", body.event.?.body);
    const done = try parser.feed(&.{});
    try std.testing.expect(done.event.? == .complete);
    var invalid = try HttpParser.init(.{ .kind = .request });
    try std.testing.expectError(error.InvalidToken, invalid.feed("GE@ / HTTP/1.1\r\n"));
}

test "HTTP parser rejects conflicting and oversized framing without unbounded retention" {
    var parser = try HttpParser.init(.{ .kind = .request, .maximum_start_line_bytes = 32, .maximum_header_bytes = 32, .maximum_headers = 1, .maximum_body_bytes = 2 });
    _ = try parser.feed("GET / HTTP/1.1\r\n");
    try std.testing.expectError(error.HeaderTooLarge, parser.feed("Long: 123456789012345678901234567890\r\n"));
    var chunked = try HttpParser.init(.{ .kind = .response, .maximum_body_bytes = 2 });
    const wire = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\n";
    const status = try chunked.feed(wire);
    const transfer = try chunked.feed(wire[status.consumed..]);
    const headers = try chunked.feed(wire[status.consumed + transfer.consumed ..]);
    try std.testing.expect(headers.event.? == .headers_complete);
    try std.testing.expectError(error.BodyTooLarge, chunked.feed(wire[status.consumed + transfer.consumed + headers.consumed ..]));
}
