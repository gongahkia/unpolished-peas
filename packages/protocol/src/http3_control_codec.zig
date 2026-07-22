const std = @import("std");

pub const max_quic_varint: u64 = (1 << 62) - 1;
pub const max_http3_control_frame_bytes: usize = 64 * 1024;
pub const max_http3_settings: usize = 64;
pub const Http3ControlCodecError = error{ InvalidConfiguration, OutputTooSmall, IncompleteFrame, FrameTooLarge, VarintOutOfRange, InvalidSettings, DuplicateSetting, ReservedSetting };

pub const Http3FrameType = enum(u64) {
    data = 0x00,
    headers = 0x01,
    cancel_push = 0x03,
    settings = 0x04,
    push_promise = 0x05,
    goaway = 0x07,
    max_push_id = 0x0d,
    _,
};

pub const Http3ControlCodecConfig = struct {
    maximum_frame_bytes: usize = max_http3_control_frame_bytes,
    maximum_settings: usize = max_http3_settings,

    pub fn validate(self: Http3ControlCodecConfig) Http3ControlCodecError!void {
        if (self.maximum_frame_bytes == 0 or self.maximum_frame_bytes > max_http3_control_frame_bytes or self.maximum_settings == 0 or self.maximum_settings > max_http3_settings) return error.InvalidConfiguration;
    }
};

pub const QuicVarint = struct {
    value: u64,
    consumed: usize,
};

pub const Http3ControlFrame = struct {
    frame_type: u64,
    payload: []const u8,
};

pub const Http3DecodedControlFrame = struct {
    consumed: usize,
    frame: Http3ControlFrame,
};

pub const Http3Setting = struct {
    id: u64,
    value: u64,
};

pub fn quic_varint_encoded_len(value: u64) Http3ControlCodecError!usize {
    if (value > max_quic_varint) return error.VarintOutOfRange;
    if (value <= 63) return 1;
    if (value <= 16_383) return 2;
    if (value <= 1_073_741_823) return 4;
    return 8;
}

pub fn encode_quic_varint(value: u64, output: []u8) Http3ControlCodecError![]u8 {
    const length = try quic_varint_encoded_len(value);
    if (output.len < length) return error.OutputTooSmall;
    switch (length) {
        1 => output[0] = @intCast(value),
        2 => std.mem.writeInt(u16, output[0..2], @as(u16, @intCast(value)) | 0x4000, .big),
        4 => std.mem.writeInt(u32, output[0..4], @as(u32, @intCast(value)) | 0x80000000, .big),
        8 => std.mem.writeInt(u64, output[0..8], value | 0xc000000000000000, .big),
        else => unreachable,
    }
    return output[0..length];
}

pub fn decode_quic_varint(input: []const u8) Http3ControlCodecError!QuicVarint {
    if (input.len == 0) return error.IncompleteFrame;
    const length: usize = @as(usize, 1) << @as(u3, @intCast(input[0] >> 6));
    if (input.len < length) return error.IncompleteFrame;
    const value = switch (length) {
        1 => @as(u64, input[0] & 0x3f),
        2 => @as(u64, std.mem.readInt(u16, input[0..2], .big) & 0x3fff),
        4 => @as(u64, std.mem.readInt(u32, input[0..4], .big) & 0x3fffffff),
        8 => std.mem.readInt(u64, input[0..8], .big) & max_quic_varint,
        else => unreachable,
    };
    return .{ .value = value, .consumed = length };
}

pub fn http3_control_frame_encoded_len(config: Http3ControlCodecConfig, frame: Http3ControlFrame) Http3ControlCodecError!usize {
    try config.validate();
    if (frame.payload.len > config.maximum_frame_bytes) return error.FrameTooLarge;
    const type_length = try quic_varint_encoded_len(frame.frame_type);
    const payload_length = try quic_varint_encoded_len(frame.payload.len);
    return std.math.add(usize, std.math.add(usize, type_length, payload_length) catch return error.FrameTooLarge, frame.payload.len) catch return error.FrameTooLarge;
}

pub fn encode_http3_control_frame(config: Http3ControlCodecConfig, frame: Http3ControlFrame, output: []u8) Http3ControlCodecError![]u8 {
    const total = try http3_control_frame_encoded_len(config, frame);
    if (output.len < total) return error.OutputTooSmall;
    var offset: usize = 0;
    offset += (try encode_quic_varint(frame.frame_type, output[offset..])).len;
    offset += (try encode_quic_varint(frame.payload.len, output[offset..])).len;
    @memcpy(output[offset..total], frame.payload);
    return output[0..total];
}

pub fn decode_http3_control_frame(config: Http3ControlCodecConfig, input: []const u8) Http3ControlCodecError!Http3DecodedControlFrame {
    try config.validate();
    const frame_type = try decode_quic_varint(input);
    const payload_length = try decode_quic_varint(input[frame_type.consumed..]);
    const payload_len = std.math.cast(usize, payload_length.value) orelse return error.FrameTooLarge;
    if (payload_len > config.maximum_frame_bytes) return error.FrameTooLarge;
    const header_length = std.math.add(usize, frame_type.consumed, payload_length.consumed) catch return error.FrameTooLarge;
    const total = std.math.add(usize, header_length, payload_len) catch return error.FrameTooLarge;
    if (input.len < total) return error.IncompleteFrame;
    return .{ .consumed = total, .frame = .{ .frame_type = frame_type.value, .payload = input[header_length..total] } };
}

pub fn http3_settings_encoded_len(config: Http3ControlCodecConfig, settings: []const Http3Setting) Http3ControlCodecError!usize {
    try validate_http3_settings(config, settings);
    var payload_len: usize = 0;
    for (settings) |setting| {
        payload_len = std.math.add(usize, payload_len, try quic_varint_encoded_len(setting.id)) catch return error.FrameTooLarge;
        payload_len = std.math.add(usize, payload_len, try quic_varint_encoded_len(setting.value)) catch return error.FrameTooLarge;
    }
    if (payload_len > config.maximum_frame_bytes) return error.FrameTooLarge;
    const type_len = try quic_varint_encoded_len(@intFromEnum(Http3FrameType.settings));
    const payload_len_len = try quic_varint_encoded_len(payload_len);
    return std.math.add(usize, std.math.add(usize, type_len, payload_len_len) catch return error.FrameTooLarge, payload_len) catch return error.FrameTooLarge;
}

pub fn encode_http3_settings(config: Http3ControlCodecConfig, settings: []const Http3Setting, output: []u8) Http3ControlCodecError![]u8 {
    const total = try http3_settings_encoded_len(config, settings);
    if (output.len < total) return error.OutputTooSmall;
    var payload_len: usize = 0;
    for (settings) |setting| {
        payload_len += try quic_varint_encoded_len(setting.id);
        payload_len += try quic_varint_encoded_len(setting.value);
    }
    var offset: usize = 0;
    offset += (try encode_quic_varint(@intFromEnum(Http3FrameType.settings), output[offset..])).len;
    offset += (try encode_quic_varint(payload_len, output[offset..])).len;
    for (settings) |setting| {
        offset += (try encode_quic_varint(setting.id, output[offset..])).len;
        offset += (try encode_quic_varint(setting.value, output[offset..])).len;
    }
    return output[0..offset];
}

pub fn decode_http3_settings(config: Http3ControlCodecConfig, payload: []const u8, output: []Http3Setting) Http3ControlCodecError![]Http3Setting {
    try config.validate();
    var offset: usize = 0;
    var count: usize = 0;
    while (offset < payload.len) {
        if (count == config.maximum_settings or count == output.len) return error.OutputTooSmall;
        const id = decode_quic_varint(payload[offset..]) catch return error.InvalidSettings;
        offset += id.consumed;
        const value = decode_quic_varint(payload[offset..]) catch return error.InvalidSettings;
        offset += value.consumed;
        output[count] = .{ .id = id.value, .value = value.value };
        count += 1;
    }
    const settings = output[0..count];
    try validate_http3_settings(config, settings);
    return settings;
}

pub fn validate_http3_settings(config: Http3ControlCodecConfig, settings: []const Http3Setting) Http3ControlCodecError!void {
    try config.validate();
    if (settings.len > config.maximum_settings) return error.FrameTooLarge;
    for (settings, 0..) |setting, index| {
        if (isReservedSetting(setting.id)) return error.ReservedSetting;
        for (settings[0..index]) |previous| if (previous.id == setting.id) return error.DuplicateSetting;
    }
}

fn isReservedSetting(id: u64) bool {
    return id == 0x00 or (id >= 0x02 and id <= 0x05);
}

test "HTTP3 control codecs encode bounded settings and preserve QUIC varints" {
    const settings = [_]Http3Setting{ .{ .id = 0x01, .value = 1024 }, .{ .id = 0x06, .value = 4096 } };
    var wire: [32]u8 = undefined;
    const encoded = try encode_http3_settings(.{}, &settings, wire[0..]);
    try std.testing.expectEqualStrings("\x04\x06\x01\x44\x00\x06\x50\x00", encoded);
    const frame = try decode_http3_control_frame(.{}, encoded);
    try std.testing.expectEqual(@as(u64, @intFromEnum(Http3FrameType.settings)), frame.frame.frame_type);
    var decoded: [2]Http3Setting = undefined;
    try std.testing.expectEqualSlices(Http3Setting, &settings, try decode_http3_settings(.{}, frame.frame.payload, decoded[0..]));
    var varint: [8]u8 = undefined;
    try std.testing.expectEqualStrings("\x40\x40", try encode_quic_varint(64, varint[0..]));
    try std.testing.expectEqual(@as(u64, 64), (try decode_quic_varint("\x40\x40")).value);
}

test "HTTP3 control codecs reject duplicate reserved and oversized settings safely" {
    var settings: [2]Http3Setting = undefined;
    try std.testing.expectError(error.DuplicateSetting, decode_http3_settings(.{}, "\x06\x00\x06\x01", settings[0..]));
    try std.testing.expectError(error.ReservedSetting, decode_http3_settings(.{}, "\x02\x01", settings[0..]));
    try std.testing.expectError(error.FrameTooLarge, decode_http3_control_frame(.{ .maximum_frame_bytes = 4 }, "\x04\x05\x00\x00\x00\x00\x00"));
    try std.testing.expectError(error.IncompleteFrame, decode_http3_control_frame(.{}, "\x04"));
}
