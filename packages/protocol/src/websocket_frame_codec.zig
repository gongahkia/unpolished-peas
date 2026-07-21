const std = @import("std");

pub const max_websocket_frame_bytes: usize = 16 * 1024 * 1024;
pub const max_websocket_chunk_bytes: usize = 64 * 1024;
pub const WebSocketFrameError = std.mem.Allocator.Error || error{ InvalidConfiguration, InvalidState, OutputTooSmall, MalformedFrame, FrameTooLarge, MaskRequired, UnexpectedMask, UnsupportedOpcode, Fragmentation, InvalidUtf8, InvalidClose };
pub const WebSocketEndpoint = enum { client, server };
pub const WebSocketOpcode = enum(u4) { continuation = 0, text = 1, binary = 2, close = 8, ping = 9, pong = 10 };
pub const WebSocketFrameHeader = struct { fin: bool, opcode: WebSocketOpcode, payload_length: usize };
pub const WebSocketFrame = struct { fin: bool = true, opcode: WebSocketOpcode, payload: []const u8, mask_key: ?[4]u8 = null };
pub const WebSocketFrameCodecConfig = struct {
    endpoint: WebSocketEndpoint,
    maximum_frame_bytes: usize = max_websocket_frame_bytes,
    maximum_chunk_bytes: usize = max_websocket_chunk_bytes,

    pub fn validate(self: WebSocketFrameCodecConfig) WebSocketFrameError!void {
        if (self.maximum_frame_bytes == 0 or self.maximum_frame_bytes > max_websocket_frame_bytes or self.maximum_chunk_bytes == 0 or self.maximum_chunk_bytes > max_websocket_chunk_bytes) return error.InvalidConfiguration;
    }
};
pub const WebSocketFrameEvent = union(enum) { frame_start: WebSocketFrameHeader, payload: []const u8, frame_end: WebSocketFrameHeader };
pub const WebSocketParserFeed = struct { consumed: usize, event: ?WebSocketFrameEvent };

const Utf8State = struct {
    remaining: u8 = 0,
    codepoint: u32 = 0,
    minimum: u32 = 0,

    fn reset(self: *Utf8State) void {
        self.* = .{};
    }

    fn consume(self: *Utf8State, input: []const u8) WebSocketFrameError!void {
        for (input) |byte| {
            if (self.remaining == 0) {
                if (byte <= 0x7f) continue;
                if (byte >= 0xc2 and byte <= 0xdf) {
                    self.remaining = 1;
                    self.codepoint = byte & 0x1f;
                    self.minimum = 0x80;
                } else if (byte >= 0xe0 and byte <= 0xef) {
                    self.remaining = 2;
                    self.codepoint = byte & 0x0f;
                    self.minimum = 0x800;
                } else if (byte >= 0xf0 and byte <= 0xf4) {
                    self.remaining = 3;
                    self.codepoint = byte & 0x07;
                    self.minimum = 0x10000;
                } else return error.InvalidUtf8;
            } else {
                if (byte < 0x80 or byte > 0xbf) return error.InvalidUtf8;
                self.codepoint = (self.codepoint << 6) | (byte & 0x3f);
                self.remaining -= 1;
                if (self.remaining == 0 and (self.codepoint < self.minimum or self.codepoint > 0x10ffff or (self.codepoint >= 0xd800 and self.codepoint <= 0xdfff))) return error.InvalidUtf8;
            }
        }
    }
};

pub const WebSocketFrameParser = struct {
    allocator: std.mem.Allocator,
    config: WebSocketFrameCodecConfig,
    chunk: []u8,
    header: [14]u8 = undefined,
    header_length: usize = 0,
    header_required: usize = 2,
    current: ?WebSocketFrameHeader = null,
    payload_remaining: usize = 0,
    mask_key: ?[4]u8 = null,
    mask_offset: usize = 0,
    fragmented: ?WebSocketOpcode = null,
    current_message: ?WebSocketOpcode = null,
    utf8: Utf8State = .{},
    control: [125]u8 = undefined,
    control_length: usize = 0,

    pub fn init(allocator: std.mem.Allocator, config: WebSocketFrameCodecConfig) WebSocketFrameError!WebSocketFrameParser {
        try config.validate();
        return .{ .allocator = allocator, .config = config, .chunk = try allocator.alloc(u8, config.maximum_chunk_bytes) };
    }

    pub fn deinit(self: *WebSocketFrameParser) void {
        self.allocator.free(self.chunk);
        self.* = undefined;
    }

    pub fn feed(self: *WebSocketFrameParser, input: []const u8) WebSocketFrameError!WebSocketParserFeed {
        if (self.current == null) return self.feedHeader(input);
        if (self.payload_remaining == 0) return .{ .consumed = 0, .event = .{ .frame_end = try self.finishFrame() } };
        if (input.len == 0) return .{ .consumed = 0, .event = null };
        const count = @min(input.len, @min(self.payload_remaining, self.chunk.len));
        for (input[0..count], 0..) |byte, index| self.chunk[index] = if (self.mask_key) |key| byte ^ key[(self.mask_offset + index) % key.len] else byte;
        self.mask_offset += count;
        self.payload_remaining -= count;
        const header = self.current.?;
        if (isTextFrame(header.opcode, self.current_message)) try self.utf8.consume(self.chunk[0..count]);
        if (isControl(header.opcode)) {
            @memcpy(self.control[self.control_length .. self.control_length + count], self.chunk[0..count]);
            self.control_length += count;
        }
        return .{ .consumed = count, .event = .{ .payload = self.chunk[0..count] } };
    }

    fn feedHeader(self: *WebSocketFrameParser, input: []const u8) WebSocketFrameError!WebSocketParserFeed {
        var consumed: usize = 0;
        while (consumed < input.len and self.header_length < self.header_required) : (consumed += 1) {
            self.header[self.header_length] = input[consumed];
            self.header_length += 1;
            if (self.header_length == 2) try self.extendHeader();
        }
        if (self.header_length != self.header_required) return .{ .consumed = consumed, .event = null };
        const frame = try self.beginFrame();
        return .{ .consumed = consumed, .event = .{ .frame_start = frame } };
    }

    fn extendHeader(self: *WebSocketFrameParser) WebSocketFrameError!void {
        const length_code = self.header[1] & 0x7f;
        const masked = self.header[1] & 0x80 != 0;
        self.header_required = @as(usize, 2) + (if (length_code == 126) @as(usize, 2) else if (length_code == 127) @as(usize, 8) else @as(usize, 0)) + (if (masked) @as(usize, 4) else @as(usize, 0));
    }

    fn beginFrame(self: *WebSocketFrameParser) WebSocketFrameError!WebSocketFrameHeader {
        const first = self.header[0];
        if (first & 0x70 != 0) return error.MalformedFrame;
        const opcode = std.meta.intToEnum(WebSocketOpcode, first & 0x0f) catch return error.UnsupportedOpcode;
        const fin = first & 0x80 != 0;
        const masked = self.header[1] & 0x80 != 0;
        if ((self.config.endpoint == .server) != masked) return if (masked) error.UnexpectedMask else error.MaskRequired;
        const length_code = self.header[1] & 0x7f;
        var offset: usize = 2;
        const length: usize = switch (length_code) {
            126 => blk: {
                const value = std.mem.readInt(u16, self.header[offset..][0..2], .big);
                offset += 2;
                if (value < 126) return error.MalformedFrame;
                break :blk value;
            },
            127 => blk: {
                const value = std.mem.readInt(u64, self.header[offset..][0..8], .big);
                offset += 8;
                if (value & (@as(u64, 1) << 63) != 0 or value > self.config.maximum_frame_bytes) return error.FrameTooLarge;
                break :blk @intCast(value);
            },
            else => length_code,
        };
        if (length > self.config.maximum_frame_bytes) return error.FrameTooLarge;
        if (masked) {
            self.mask_key = self.header[offset..][0..4].*;
        } else self.mask_key = null;
        if (isControl(opcode) and (!fin or length > 125)) return error.MalformedFrame;
        switch (opcode) {
            .continuation => if (self.fragmented == null) return error.Fragmentation,
            .text, .binary => if (self.fragmented != null) return error.Fragmentation,
            else => {},
        }
        self.current_message = if (opcode == .continuation) self.fragmented else if (isData(opcode)) opcode else null;
        if (isData(opcode) and !fin) self.fragmented = opcode;
        self.current = .{ .fin = fin, .opcode = opcode, .payload_length = length };
        self.payload_remaining = length;
        self.mask_offset = 0;
        self.control_length = 0;
        return self.current.?;
    }

    fn finishFrame(self: *WebSocketFrameParser) WebSocketFrameError!WebSocketFrameHeader {
        const frame = self.current.?;
        if (frame.opcode == .close) try validateClose(self.control[0..self.control_length]);
        if (isTextFrame(frame.opcode, self.current_message) and frame.fin) {
            if (self.utf8.remaining != 0) return error.InvalidUtf8;
            self.utf8.reset();
        }
        if (isData(frame.opcode) and frame.fin or frame.opcode == .continuation and frame.fin) self.fragmented = null;
        self.current = null;
        self.current_message = null;
        self.header_length = 0;
        self.header_required = 2;
        self.mask_key = null;
        return frame;
    }
};

pub fn encode_websocket_frame(config: WebSocketFrameCodecConfig, frame: WebSocketFrame, output: []u8) WebSocketFrameError![]u8 {
    try config.validate();
    if (frame.payload.len > config.maximum_frame_bytes or (isControl(frame.opcode) and (!frame.fin or frame.payload.len > 125))) return error.FrameTooLarge;
    if ((config.endpoint == .client) != (frame.mask_key != null)) return if (frame.mask_key == null) error.MaskRequired else error.UnexpectedMask;
    if (frame.opcode == .text and !std.unicode.utf8ValidateSlice(frame.payload)) return error.InvalidUtf8;
    if (frame.opcode == .close) try validateClose(frame.payload);
    const extended: usize = if (frame.payload.len < 126) 0 else if (frame.payload.len <= std.math.maxInt(u16)) 2 else 8;
    const total: usize = 2 + extended + (if (frame.mask_key != null) @as(usize, 4) else @as(usize, 0)) + frame.payload.len;
    if (output.len < total) return error.OutputTooSmall;
    output[0] = @intFromEnum(frame.opcode) | if (frame.fin) 0x80 else 0;
    const mask_bit: u8 = if (frame.mask_key != null) 0x80 else 0;
    var offset: usize = 2;
    if (extended == 0) output[1] = mask_bit | @as(u8, @intCast(frame.payload.len)) else if (extended == 2) {
        output[1] = mask_bit | 126;
        std.mem.writeInt(u16, output[offset..][0..2], @intCast(frame.payload.len), .big);
        offset += 2;
    } else {
        output[1] = mask_bit | 127;
        std.mem.writeInt(u64, output[offset..][0..8], frame.payload.len, .big);
        offset += 8;
    }
    if (frame.mask_key) |key| {
        @memcpy(output[offset .. offset + 4], &key);
        offset += 4;
        for (frame.payload, 0..) |byte, index| output[offset + index] = byte ^ key[index % 4];
    } else @memcpy(output[offset..][0..frame.payload.len], frame.payload);
    return output[0..total];
}

fn isControl(opcode: WebSocketOpcode) bool {
    return @intFromEnum(opcode) >= 8;
}
fn isData(opcode: WebSocketOpcode) bool {
    return opcode == .text or opcode == .binary;
}
fn isTextFrame(opcode: WebSocketOpcode, message: ?WebSocketOpcode) bool {
    return opcode == .text or (opcode == .continuation and message == .text);
}

fn validateClose(payload: []const u8) WebSocketFrameError!void {
    if (payload.len == 1) return error.InvalidClose;
    if (payload.len >= 2) {
        const code = std.mem.readInt(u16, payload[0..2], .big);
        if (!validCloseCode(code) or !std.unicode.utf8ValidateSlice(payload[2..])) return error.InvalidClose;
    }
}

fn validCloseCode(code: u16) bool {
    return (code >= 1000 and code <= 1014 and code != 1004 and code != 1005 and code != 1006) or (code >= 3000 and code <= 4999);
}

test "incremental WebSocket frames enforce masking and reject malformed fragmentation" {
    var parser = try WebSocketFrameParser.init(std.testing.allocator, .{ .endpoint = .server, .maximum_frame_bytes = 16, .maximum_chunk_bytes = 4 });
    defer parser.deinit();
    var wire: [32]u8 = undefined;
    const frame = try encode_websocket_frame(.{ .endpoint = .client, .maximum_frame_bytes = 16 }, .{ .fin = false, .opcode = .text, .payload = "he", .mask_key = .{ 1, 2, 3, 4 } }, wire[0..]);
    var offset: usize = 0;
    _ = try parser.feed(frame[offset..]);
    offset += 6;
    const payload = try parser.feed(frame[offset..]);
    try std.testing.expectEqualStrings("he", payload.event.?.payload);
    _ = try parser.feed(&.{});
    const malformed = [_]u8{ 0x81, 0x80, 1, 2, 3, 4 };
    try std.testing.expectError(error.Fragmentation, parser.feed(&malformed));
}
