const std = @import("std");
const core = @import("minna-san-core");

pub const capture_format_magic = [_]u8{ 'M', 'S', 'C', 'P' };
pub const capture_stream_header_bytes: usize = 12;
pub const capture_record_header_bytes: usize = 24;
pub const max_capture_record_payload_bytes: usize = 65_507;
pub const capture_record_flag_redacted: u8 = 1;

pub const CaptureFormatVersion = struct {
    major: u16,
    minor: u16,
};

pub const capture_format_version = CaptureFormatVersion{ .major = 1, .minor = 0 };

pub const CaptureRecordKind = enum(u8) {
    packet = 1,
    event = 2,
    clock = 3,
    route = 4,
    configuration = 5,
};

pub const CaptureRecordFlags = struct {
    redacted: bool = false,
};

pub const CaptureStreamHeader = struct {
    version: CaptureFormatVersion = capture_format_version,
};

pub const CaptureRecord = struct {
    kind: CaptureRecordKind,
    flags: CaptureRecordFlags = .{},
    sequence: u64,
    timestamp_ns: core.TimeNs,
    payload: []const u8,
};

pub const CaptureFormatError = error{
    VersionMismatch,
    BufferTooSmall,
    PayloadTooLarge,
    MalformedCapture,
    InvalidFlags,
};

pub fn validate_capture_format_version(version: CaptureFormatVersion) CaptureFormatError!void {
    if (version.major != capture_format_version.major or version.minor > capture_format_version.minor) return error.VersionMismatch;
}

pub fn encode_capture_stream_header(header: CaptureStreamHeader, output: []u8) CaptureFormatError![]u8 {
    try validate_capture_format_version(header.version);
    if (output.len < capture_stream_header_bytes) return error.BufferTooSmall;
    @memcpy(output[0..4], &capture_format_magic);
    std.mem.writeInt(u16, output[4..6], header.version.major, .big);
    std.mem.writeInt(u16, output[6..8], header.version.minor, .big);
    std.mem.writeInt(u16, output[8..10], 0, .big);
    std.mem.writeInt(u16, output[10..12], capture_stream_header_bytes, .big);
    return output[0..capture_stream_header_bytes];
}

pub fn decode_capture_stream_header(input: []const u8) CaptureFormatError!CaptureStreamHeader {
    if (input.len < capture_stream_header_bytes or !std.mem.eql(u8, input[0..4], &capture_format_magic)) return error.MalformedCapture;
    if (std.mem.readInt(u16, input[8..10], .big) != 0 or std.mem.readInt(u16, input[10..12], .big) != capture_stream_header_bytes) return error.MalformedCapture;
    const header = CaptureStreamHeader{ .version = .{
        .major = std.mem.readInt(u16, input[4..6], .big),
        .minor = std.mem.readInt(u16, input[6..8], .big),
    } };
    try validate_capture_format_version(header.version);
    return header;
}

pub fn encode_capture_record(record: CaptureRecord, output: []u8) CaptureFormatError![]u8 {
    if (record.payload.len > max_capture_record_payload_bytes) return error.PayloadTooLarge;
    const total = std.math.add(usize, capture_record_header_bytes, record.payload.len) catch return error.PayloadTooLarge;
    if (output.len < total) return error.BufferTooSmall;
    output[0] = @intFromEnum(record.kind);
    output[1] = record_flags_bits(record.flags);
    std.mem.writeInt(u16, output[2..4], 0, .big);
    std.mem.writeInt(u64, output[4..12], record.sequence, .big);
    std.mem.writeInt(core.TimeNs, output[12..20], record.timestamp_ns, .big);
    std.mem.writeInt(u32, output[20..24], @intCast(record.payload.len), .big);
    @memcpy(output[capture_record_header_bytes..total], record.payload);
    return output[0..total];
}

pub fn decode_capture_record(input: []const u8) CaptureFormatError!CaptureRecord {
    if (input.len < capture_record_header_bytes) return error.MalformedCapture;
    const kind = std.meta.intToEnum(CaptureRecordKind, input[0]) catch return error.MalformedCapture;
    const flags = decode_record_flags(input[1]) catch return error.InvalidFlags;
    if (std.mem.readInt(u16, input[2..4], .big) != 0) return error.MalformedCapture;
    const payload_len: usize = std.mem.readInt(u32, input[20..24], .big);
    if (payload_len > max_capture_record_payload_bytes) return error.PayloadTooLarge;
    const total = std.math.add(usize, capture_record_header_bytes, payload_len) catch return error.MalformedCapture;
    if (input.len != total) return error.MalformedCapture;
    return .{
        .kind = kind,
        .flags = flags,
        .sequence = std.mem.readInt(u64, input[4..12], .big),
        .timestamp_ns = std.mem.readInt(core.TimeNs, input[12..20], .big),
        .payload = input[capture_record_header_bytes..],
    };
}

fn record_flags_bits(flags: CaptureRecordFlags) u8 {
    return if (flags.redacted) capture_record_flag_redacted else 0;
}

fn decode_record_flags(bits: u8) CaptureFormatError!CaptureRecordFlags {
    if (bits & ~capture_record_flag_redacted != 0) return error.InvalidFlags;
    return .{ .redacted = bits & capture_record_flag_redacted != 0 };
}

test "capture format preserves versioned packet event clock route and configuration records" {
    var header_storage: [capture_stream_header_bytes]u8 = undefined;
    const encoded_header = try encode_capture_stream_header(.{}, header_storage[0..]);
    try std.testing.expectEqual(CaptureStreamHeader{}, try decode_capture_stream_header(encoded_header));
    inline for ([_]CaptureRecordKind{ .packet, .event, .clock, .route, .configuration }) |kind| {
        var record_storage: [capture_record_header_bytes + 7]u8 = undefined;
        const record = CaptureRecord{ .kind = kind, .flags = .{ .redacted = kind == .configuration }, .sequence = @intFromEnum(kind), .timestamp_ns = 42, .payload = "capture" };
        const encoded_record = try encode_capture_record(record, record_storage[0..]);
        const decoded_record = try decode_capture_record(encoded_record);
        try std.testing.expectEqual(record.kind, decoded_record.kind);
        try std.testing.expectEqual(record.flags, decoded_record.flags);
        try std.testing.expectEqual(record.sequence, decoded_record.sequence);
        try std.testing.expectEqual(record.timestamp_ns, decoded_record.timestamp_ns);
        try std.testing.expectEqualStrings(record.payload, decoded_record.payload);
    }
}

test "capture format rejects malformed unbounded and incompatible frames" {
    var header_storage: [capture_stream_header_bytes]u8 = undefined;
    _ = try encode_capture_stream_header(.{}, header_storage[0..]);
    header_storage[0] = 0;
    try std.testing.expectError(error.MalformedCapture, decode_capture_stream_header(header_storage[0..]));
    try std.testing.expectError(error.VersionMismatch, validate_capture_format_version(.{ .major = 2, .minor = 0 }));
    var short_output: [capture_record_header_bytes - 1]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, encode_capture_record(.{ .kind = .packet, .sequence = 0, .timestamp_ns = 0, .payload = "" }, short_output[0..]));
    var record_storage: [capture_record_header_bytes]u8 = undefined;
    _ = try encode_capture_record(.{ .kind = .event, .sequence = 0, .timestamp_ns = 0, .payload = "" }, record_storage[0..]);
    record_storage[0] = 0xff;
    try std.testing.expectError(error.MalformedCapture, decode_capture_record(record_storage[0..]));
    record_storage[0] = @intFromEnum(CaptureRecordKind.event);
    record_storage[1] = 2;
    try std.testing.expectError(error.InvalidFlags, decode_capture_record(record_storage[0..]));
    var oversized: [max_capture_record_payload_bytes + 1]u8 = undefined;
    try std.testing.expectError(error.PayloadTooLarge, encode_capture_record(.{ .kind = .packet, .sequence = 0, .timestamp_ns = 0, .payload = oversized[0..] }, oversized[0..]));
}
