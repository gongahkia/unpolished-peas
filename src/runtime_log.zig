const std = @import("std");

pub const schema_version: u32 = 1;
pub const max_fields: usize = 16;
pub const max_text_bytes: usize = 1024;

pub const Level = enum { trace, debug, info, warn, err, fatal };
pub const Category = enum { engine, assets, render, input, audio, storage, diagnostics, platform };
pub const Value = union(enum) { string: []const u8, integer: i64, boolean: bool };
pub const Field = struct { key: []const u8, value: Value };

pub const Event = struct {
    timestamp_ns: u64,
    session_id: u64,
    frame_id: ?u64 = null,
    level: Level,
    category: Category,
    message: []const u8,
    fields: []const Field = &.{},

    pub fn validate(self: Event) !void {
        if (self.message.len > max_text_bytes or self.fields.len > max_fields) return error.InvalidLogEvent;
        for (self.fields, 0..) |field, index| {
            if (!validKey(field.key)) return error.InvalidLogField;
            switch (field.value) {
                .string => |value| if (value.len > max_text_bytes) return error.InvalidLogField,
                else => {},
            }
            for (self.fields[0..index]) |prior| if (std.mem.eql(u8, prior.key, field.key)) return error.DuplicateLogField;
        }
    }
};

pub fn writeJsonl(writer: anytype, event: Event) !void {
    try event.validate();
    try writer.writeAll("{\"version\":");
    try writer.print("{d}", .{schema_version});
    try writer.writeAll(",\"timestamp_ns\":");
    try writer.print("{d}", .{event.timestamp_ns});
    try writer.writeAll(",\"session_id\":");
    try writer.print("{d}", .{event.session_id});
    try writer.writeAll(",\"frame_id\":");
    if (event.frame_id) |frame| try writer.print("{d}", .{frame}) else try writer.writeAll("null");
    try writer.writeAll(",\"level\":");
    try std.json.stringify(@tagName(event.level), .{}, writer);
    try writer.writeAll(",\"category\":");
    try std.json.stringify(@tagName(event.category), .{}, writer);
    try writer.writeAll(",\"message\":");
    try std.json.stringify(event.message, .{}, writer);
    try writer.writeAll(",\"fields\":{");
    for (event.fields, 0..) |field, index| {
        if (index != 0) try writer.writeByte(',');
        try std.json.stringify(field.key, .{}, writer);
        try writer.writeByte(':');
        switch (field.value) {
            .string => |value| try std.json.stringify(value, .{}, writer),
            .integer => |value| try writer.print("{d}", .{value}),
            .boolean => |value| try writer.writeAll(if (value) "true" else "false"),
        }
    }
    try writer.writeAll("}}\n");
}

fn validKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 64) return false;
    for (key) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '.')) return false;
    return true;
}

test "runtime log schema writes stable JSONL" {
    var bytes: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try writeJsonl(&writer, .{ .timestamp_ns = 42, .session_id = 7, .frame_id = 3, .level = .warn, .category = .render, .message = "shader \"slow\"", .fields = &.{ .{ .key = "draws", .value = .{ .integer = 2 } }, .{ .key = "cached", .value = .{ .boolean = true } } } });
    try std.testing.expectEqualStrings("{\"version\":1,\"timestamp_ns\":42,\"session_id\":7,\"frame_id\":3,\"level\":\"warn\",\"category\":\"render\",\"message\":\"shader \\\"slow\\\"\",\"fields\":{\"draws\":2,\"cached\":true}}\n", writer.buffered());
}

test "runtime log schema rejects unstable fields" {
    const duplicate = Event{ .timestamp_ns = 0, .session_id = 0, .level = .info, .category = .engine, .message = "ok", .fields = &.{ .{ .key = "same", .value = .{ .boolean = true } }, .{ .key = "same", .value = .{ .boolean = false } } } };
    try std.testing.expectError(error.DuplicateLogField, duplicate.validate());
    try std.testing.expectError(error.InvalidLogField, (Event{ .timestamp_ns = 0, .session_id = 0, .level = .info, .category = .engine, .message = "ok", .fields = &.{.{ .key = "bad key", .value = .{ .integer = 1 } }} }).validate());
}
