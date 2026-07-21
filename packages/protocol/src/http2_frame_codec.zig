const std = @import("std");

pub const http2_frame_header_bytes: usize = 9;
pub const http2_default_max_frame_bytes: usize = 16 * 1024;
pub const http2_max_frame_bytes: usize = (1 << 24) - 1;
pub const Http2FrameError = error{ InvalidConfiguration, OutputTooSmall, IncompleteFrame, FrameTooLarge, ReservedStreamBit, ProtocolError, InvalidSettings, DuplicateSetting };
pub const Http2FrameType = enum(u8) { data = 0, headers = 1, priority = 2, rst_stream = 3, settings = 4, push_promise = 5, ping = 6, goaway = 7, window_update = 8, continuation = 9, _ };
pub const Http2Frame = struct { frame_type: Http2FrameType, flags: u8, stream_id: u32, payload: []const u8 };
pub const Http2FrameCodecConfig = struct {
    maximum_frame_bytes: usize = http2_default_max_frame_bytes,

    pub fn validate(self: Http2FrameCodecConfig) Http2FrameError!void {
        if (self.maximum_frame_bytes < http2_default_max_frame_bytes or self.maximum_frame_bytes > http2_max_frame_bytes) return error.InvalidConfiguration;
    }
};
pub const Http2Setting = struct { id: u16, value: u32 };

pub fn encode_http2_frame(config: Http2FrameCodecConfig, frame: Http2Frame, output: []u8) Http2FrameError![]u8 {
    try config.validate();
    try validateFrame(config, frame);
    const total = http2_frame_header_bytes + frame.payload.len;
    if (output.len < total) return error.OutputTooSmall;
    output[0] = @intCast(frame.payload.len >> 16);
    output[1] = @intCast(frame.payload.len >> 8);
    output[2] = @intCast(frame.payload.len);
    output[3] = @intFromEnum(frame.frame_type);
    output[4] = frame.flags;
    std.mem.writeInt(u32, output[5..9], frame.stream_id, .big);
    @memcpy(output[9..total], frame.payload);
    return output[0..total];
}

pub fn decode_http2_frame(config: Http2FrameCodecConfig, input: []const u8) Http2FrameError!struct { consumed: usize, frame: Http2Frame } {
    try config.validate();
    if (input.len < http2_frame_header_bytes) return error.IncompleteFrame;
    const length = (@as(usize, input[0]) << 16) | (@as(usize, input[1]) << 8) | input[2];
    if (length > config.maximum_frame_bytes) return error.FrameTooLarge;
    const total = http2_frame_header_bytes + length;
    if (input.len < total) return error.IncompleteFrame;
    const stream_id = std.mem.readInt(u32, input[5..9], .big);
    const frame = Http2Frame{ .frame_type = @enumFromInt(input[3]), .flags = input[4], .stream_id = stream_id, .payload = input[9..total] };
    try validateFrame(config, frame);
    return .{ .consumed = total, .frame = frame };
}

pub fn encode_http2_settings(config: Http2FrameCodecConfig, settings: []const Http2Setting, output: []u8) Http2FrameError![]u8 {
    try config.validate();
    if (settings.len > config.maximum_frame_bytes / 6) return error.FrameTooLarge;
    try validateSettings(settings);
    const total = http2_frame_header_bytes + settings.len * 6;
    if (output.len < total) return error.OutputTooSmall;
    output[0] = @intCast((settings.len * 6) >> 16);
    output[1] = @intCast((settings.len * 6) >> 8);
    output[2] = @intCast(settings.len * 6);
    output[3] = @intFromEnum(Http2FrameType.settings);
    output[4] = 0;
    @memset(output[5..9], 0);
    for (settings, 0..) |setting, index| {
        std.mem.writeInt(u16, output[9 + index * 6 ..][0..2], setting.id, .big);
        std.mem.writeInt(u32, output[9 + index * 6 + 2 ..][0..4], setting.value, .big);
    }
    return output[0..total];
}

pub fn decode_http2_settings(payload: []const u8, output: []Http2Setting) Http2FrameError![]Http2Setting {
    if (payload.len % 6 != 0 or output.len < payload.len / 6) return error.InvalidSettings;
    for (output[0 .. payload.len / 6], 0..) |*setting, index| setting.* = .{ .id = std.mem.readInt(u16, payload[index * 6 ..][0..2], .big), .value = std.mem.readInt(u32, payload[index * 6 + 2 ..][0..4], .big) };
    const settings = output[0 .. payload.len / 6];
    try validateSettings(settings);
    return settings;
}

fn validateFrame(config: Http2FrameCodecConfig, frame: Http2Frame) Http2FrameError!void {
    if (frame.payload.len > config.maximum_frame_bytes) return error.FrameTooLarge;
    if (frame.stream_id & 0x80000000 != 0) return error.ReservedStreamBit;
    switch (frame.frame_type) {
        .data, .headers, .push_promise, .continuation => if (frame.stream_id == 0) return error.ProtocolError,
        .priority => if (frame.payload.len != 5) return error.ProtocolError,
        .rst_stream => if (frame.payload.len != 4) return error.ProtocolError,
        .settings => {
            if (frame.stream_id != 0 or (frame.flags & 1 != 0 and frame.payload.len != 0) or (frame.flags & 1 == 0 and frame.payload.len % 6 != 0)) return error.ProtocolError;
            if (frame.flags & 1 == 0) try validateSettingsPayload(frame.payload);
        },
        .ping => if (frame.stream_id != 0 or frame.payload.len != 8) return error.ProtocolError,
        .goaway => if (frame.stream_id != 0 or frame.payload.len < 8 or std.mem.readInt(u32, frame.payload[0..4], .big) & 0x80000000 != 0) return error.ProtocolError,
        .window_update => if (frame.payload.len != 4 or std.mem.readInt(u32, frame.payload[0..4], .big) & 0x80000000 != 0 or std.mem.readInt(u32, frame.payload[0..4], .big) == 0) return error.ProtocolError,
        else => {},
    }
}

fn validateSettings(settings: []const Http2Setting) Http2FrameError!void {
    for (settings, 0..) |setting, index| {
        for (settings[0..index]) |previous| if (previous.id == setting.id) return error.DuplicateSetting;
        switch (setting.id) {
            2 => if (setting.value > 1) return error.InvalidSettings,
            4 => if (setting.value > 0x7fffffff) return error.InvalidSettings,
            5 => if (setting.value < http2_default_max_frame_bytes or setting.value > http2_max_frame_bytes) return error.InvalidSettings,
            else => {},
        }
    }
}

fn validateSettingsPayload(payload: []const u8) Http2FrameError!void {
    var index: usize = 0;
    while (index < payload.len) : (index += 6) {
        const setting = Http2Setting{ .id = std.mem.readInt(u16, payload[index..][0..2], .big), .value = std.mem.readInt(u32, payload[index + 2 ..][0..4], .big) };
        switch (setting.id) {
            2 => if (setting.value > 1) return error.InvalidSettings,
            4 => if (setting.value > 0x7fffffff) return error.InvalidSettings,
            5 => if (setting.value < http2_default_max_frame_bytes or setting.value > http2_max_frame_bytes) return error.InvalidSettings,
            else => {},
        }
        var previous: usize = 0;
        while (previous < index) : (previous += 6) if (std.mem.readInt(u16, payload[previous..][0..2], .big) == setting.id) return error.DuplicateSetting;
    }
}

test "HTTP2 settings fixtures round trip and malformed frames fail safely" {
    const settings = [_]Http2Setting{ .{ .id = 2, .value = 0 }, .{ .id = 4, .value = 65535 } };
    var encoded: [32]u8 = undefined;
    const wire = try encode_http2_settings(.{}, &settings, encoded[0..]);
    try std.testing.expectEqualStrings("\x00\x00\x0c\x04\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x04\x00\x00\xff\xff", wire);
    const decoded = try decode_http2_frame(.{}, wire);
    try std.testing.expectEqual(Http2FrameType.settings, decoded.frame.frame_type);
    var parsed: [2]Http2Setting = undefined;
    try std.testing.expectEqualSlices(Http2Setting, &settings, try decode_http2_settings(decoded.frame.payload, parsed[0..]));
    try std.testing.expectError(error.ProtocolError, decode_http2_frame(.{}, "\x00\x00\x00\x04\x00\x00\x00\x00\x01"));
    try std.testing.expectError(error.InvalidSettings, decode_http2_settings("\x00\x02\x00\x00\x00\x02", parsed[0..]));
    try std.testing.expectError(error.InvalidSettings, decode_http2_frame(.{}, "\x00\x00\x06\x04\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x02"));
}
