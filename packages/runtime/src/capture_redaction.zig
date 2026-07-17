const std = @import("std");
const format = @import("capture_format.zig");

pub const CaptureRedactionClass = enum {
    key,
    credential,
    payload,
    address,
    consumer,
};

pub const CaptureRedactionField = struct {
    class: CaptureRedactionClass,
    offset: usize,
    len: usize,
};

pub const CaptureConsumerRedactionFn = *const fn (?*anyopaque, CaptureRedactionField) bool;

pub const CaptureRedactionConfig = struct {
    redact_keys: bool = true,
    redact_credentials: bool = true,
    redact_payloads: bool = false,
    redact_addresses: bool = true,
    consumer_context: ?*anyopaque = null,
    redact_consumer_field: ?CaptureConsumerRedactionFn = null,
};

pub const CaptureRedactionResult = struct {
    record: format.CaptureRecord,
    redacted_fields: usize,
};

pub const CaptureRedactionError = error{
    OutputTooSmall,
    InvalidField,
};

pub const CaptureRedactor = struct {
    config: CaptureRedactionConfig,

    pub fn init(config: CaptureRedactionConfig) CaptureRedactor {
        return .{ .config = config };
    }

    pub fn redact(self: CaptureRedactor, record_value: format.CaptureRecord, fields: []const CaptureRedactionField, output: []u8) CaptureRedactionError!CaptureRedactionResult {
        if (output.len < record_value.payload.len) return error.OutputTooSmall;
        for (fields) |field| _ = try field_end(field, record_value.payload.len);
        @memcpy(output[0..record_value.payload.len], record_value.payload);
        var redacted_fields: usize = 0;
        for (fields) |field| {
            if (!self.should_redact(field)) continue;
            const end = field_end(field, record_value.payload.len) catch unreachable;
            @memset(output[field.offset..end], 0);
            redacted_fields += 1;
        }
        var redacted_record = record_value;
        redacted_record.payload = output[0..record_value.payload.len];
        if (redacted_fields != 0) redacted_record.flags.redacted = true;
        return .{ .record = redacted_record, .redacted_fields = redacted_fields };
    }

    fn should_redact(self: CaptureRedactor, field: CaptureRedactionField) bool {
        return switch (field.class) {
            .key => self.config.redact_keys,
            .credential => self.config.redact_credentials,
            .payload => self.config.redact_payloads,
            .address => self.config.redact_addresses,
            .consumer => if (self.config.redact_consumer_field) |callback| callback(self.config.consumer_context, field) else false,
        };
    }
};

fn field_end(field: CaptureRedactionField, payload_len: usize) CaptureRedactionError!usize {
    const end = std.math.add(usize, field.offset, field.len) catch return error.InvalidField;
    if (field.offset > payload_len or end > payload_len) return error.InvalidField;
    return end;
}

test "capture redactors zero keys credentials payloads addresses and consumer fields" {
    const Consumer = struct {
        fn redact(_: ?*anyopaque, field: CaptureRedactionField) bool {
            return field.offset == 4;
        }
    };
    const redactor = CaptureRedactor.init(.{ .redact_payloads = true, .redact_consumer_field = Consumer.redact });
    const fields = [_]CaptureRedactionField{
        .{ .class = .key, .offset = 0, .len = 1 },
        .{ .class = .credential, .offset = 1, .len = 1 },
        .{ .class = .payload, .offset = 2, .len = 1 },
        .{ .class = .address, .offset = 3, .len = 1 },
        .{ .class = .consumer, .offset = 4, .len = 1 },
    };
    var output: [5]u8 = undefined;
    const result = try redactor.redact(.{ .kind = .packet, .sequence = 0, .timestamp_ns = 0, .payload = "abcde" }, fields[0..], output[0..]);
    try std.testing.expect(result.record.flags.redacted);
    try std.testing.expectEqual(@as(usize, 5), result.redacted_fields);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0, 0 }, result.record.payload);
}

test "capture redactors preserve output on invalid fields and require capacity" {
    const redactor = CaptureRedactor.init(.{ .redact_keys = false, .redact_credentials = false, .redact_addresses = false });
    var output = [_]u8{9} ** 3;
    const invalid = [_]CaptureRedactionField{.{ .class = .key, .offset = 2, .len = 2 }};
    try std.testing.expectError(error.InvalidField, redactor.redact(.{ .kind = .configuration, .sequence = 0, .timestamp_ns = 0, .payload = "abc" }, invalid[0..], output[0..]));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 9, 9, 9 }, &output);
    var short_output: [2]u8 = undefined;
    try std.testing.expectError(error.OutputTooSmall, redactor.redact(.{ .kind = .configuration, .sequence = 0, .timestamp_ns = 0, .payload = "abc" }, &.{}, short_output[0..]));
}
