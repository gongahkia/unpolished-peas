const std = @import("std");

pub const schema_version: u32 = 1;
pub const max_fields: usize = 16;
pub const max_text_bytes: usize = 1024;

pub const Level = enum { trace, debug, info, warn, err, fatal };
pub const Category = enum { engine, assets, render, input, audio, storage, diagnostics, platform };
pub const Value = union(enum) { string: []const u8, integer: i64, boolean: bool };
pub const Field = struct { key: []const u8, value: Value };

pub const Filter = struct {
    min_level: Level = .info,
    category_mask: u32 = std.math.maxInt(u32),

    pub fn allows(self: Filter, event: Event) bool {
        return @intFromEnum(event.level) >= @intFromEnum(self.min_level) and (self.category_mask & (@as(u32, 1) << @intCast(@intFromEnum(event.category)))) != 0;
    }
};

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
    try std.json.Stringify.value(@tagName(event.level), .{}, writer);
    try writer.writeAll(",\"category\":");
    try std.json.Stringify.value(@tagName(event.category), .{}, writer);
    try writer.writeAll(",\"message\":");
    try std.json.Stringify.value(event.message, .{}, writer);
    try writer.writeAll(",\"fields\":{");
    for (event.fields, 0..) |field, index| {
        if (index != 0) try writer.writeByte(',');
        try std.json.Stringify.value(field.key, .{}, writer);
        try writer.writeByte(':');
        switch (field.value) {
            .string => |value| try std.json.Stringify.value(value, .{}, writer),
            .integer => |value| try writer.print("{d}", .{value}),
            .boolean => |value| try writer.writeAll(if (value) "true" else "false"),
        }
    }
    try writer.writeAll("}}\n");
}

pub fn writeFilteredJsonl(writer: anytype, filter: Filter, event: Event) !void {
    if (!filter.allows(event)) return;
    try writeJsonl(writer, event);
}

pub fn writeTerminal(writer: anytype, filter: Filter, event: Event) !void {
    if (!filter.allows(event)) return;
    try event.validate();
    try writer.print("ts={d} session={d}", .{ event.timestamp_ns, event.session_id });
    if (event.frame_id) |frame| try writer.print(" frame={d}", .{frame});
    try writer.print(" level={s} category={s} message=", .{ @tagName(event.level), @tagName(event.category) });
    try std.json.Stringify.value(event.message, .{}, writer);
    for (event.fields) |field| {
        try writer.print(" {s}=", .{field.key});
        switch (field.value) {
            .string => |value| try std.json.Stringify.value(value, .{}, writer),
            .integer => |value| try writer.print("{d}", .{value}),
            .boolean => |value| try writer.writeAll(if (value) "true" else "false"),
        }
    }
    try writer.writeByte('\n');
}

pub const Ring = struct {
    allocator: std.mem.Allocator,
    filter: Filter = .{},
    capacity: usize,
    events: std.ArrayListUnmanaged(Event) = .{},

    pub fn init(allocator: std.mem.Allocator, capacity: usize, filter: Filter) Ring {
        return .{ .allocator = allocator, .capacity = capacity, .filter = filter };
    }

    pub fn deinit(self: *Ring) void {
        for (self.events.items) |event| freeEvent(self.allocator, event);
        self.events.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn append(self: *Ring, event: Event) !void {
        if (!self.filter.allows(event) or self.capacity == 0) return;
        try event.validate();
        if (self.events.items.len == self.capacity) {
            freeEvent(self.allocator, self.events.items[0]);
            std.mem.copyForwards(Event, self.events.items[0 .. self.events.items.len - 1], self.events.items[1..]);
            self.events.items.len -= 1;
        }
        try self.events.append(self.allocator, try copyEvent(self.allocator, event));
    }

    pub fn items(self: *const Ring) []const Event {
        return self.events.items;
    }
};

fn copyEvent(allocator: std.mem.Allocator, event: Event) !Event {
    const fields = try allocator.alloc(Field, event.fields.len);
    errdefer allocator.free(fields);
    for (event.fields, 0..) |field, index| {
        fields[index].key = try allocator.dupe(u8, field.key);
        errdefer allocator.free(fields[index].key);
        fields[index].value = switch (field.value) {
            .string => |value| .{ .string = try allocator.dupe(u8, value) },
            .integer => |value| .{ .integer = value },
            .boolean => |value| .{ .boolean = value },
        };
    }
    return .{ .timestamp_ns = event.timestamp_ns, .session_id = event.session_id, .frame_id = event.frame_id, .level = event.level, .category = event.category, .message = try allocator.dupe(u8, event.message), .fields = fields };
}

fn freeEvent(allocator: std.mem.Allocator, event: Event) void {
    allocator.free(event.message);
    for (event.fields) |field| {
        allocator.free(field.key);
        switch (field.value) {
            .string => |value| allocator.free(value),
            else => {},
        }
    }
    allocator.free(event.fields);
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

test "runtime log sinks share filters and retain bounded owned events" {
    const filter = Filter{ .min_level = .warn, .category_mask = @as(u32, 1) << @intFromEnum(Category.render) };
    const quiet = Event{ .timestamp_ns = 1, .session_id = 2, .level = .info, .category = .render, .message = "quiet" };
    const first = Event{ .timestamp_ns = 2, .session_id = 2, .level = .warn, .category = .render, .message = "first" };
    const second = Event{ .timestamp_ns = 3, .session_id = 2, .level = .err, .category = .render, .message = "second" };
    var output: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try writeTerminal(&writer, filter, quiet);
    try writeFilteredJsonl(&writer, filter, first);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "quiet") == null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\"message\":\"first\"") != null);
    var ring = Ring.init(std.testing.allocator, 1, filter);
    defer ring.deinit();
    try ring.append(quiet);
    try ring.append(first);
    try ring.append(second);
    try std.testing.expectEqual(@as(usize, 1), ring.items().len);
    try std.testing.expectEqualStrings("second", ring.items()[0].message);
}
