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
    dropped_events: u64 = 0,

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
        // Complete both fallible allocations before evicting an existing event.
        try self.events.ensureUnusedCapacity(self.allocator, 1);
        const owned = try copyEvent(self.allocator, event);
        if (self.events.items.len == self.capacity) {
            freeEvent(self.allocator, self.events.items[0]);
            std.mem.copyForwards(Event, self.events.items[0 .. self.events.items.len - 1], self.events.items[1..]);
            self.events.items.len -= 1;
            self.dropped_events +|= 1;
        }
        self.events.appendAssumeCapacity(owned);
    }

    pub fn items(self: *const Ring) []const Event {
        return self.events.items;
    }
};

fn copyEvent(allocator: std.mem.Allocator, event: Event) !Event {
    const message = try allocator.dupe(u8, event.message);
    errdefer allocator.free(message);
    const fields = try allocator.alloc(Field, event.fields.len);
    errdefer allocator.free(fields);
    var initialized: usize = 0;
    errdefer for (fields[0..initialized]) |field| freeField(allocator, field);
    for (event.fields, 0..) |field, index| {
        const key = try allocator.dupe(u8, field.key);
        errdefer allocator.free(key);
        fields[index] = .{ .key = key, .value = switch (field.value) {
            .string => |value| .{ .string = try allocator.dupe(u8, value) },
            .integer => |value| .{ .integer = value },
            .boolean => |value| .{ .boolean = value },
        } };
        initialized += 1;
    }
    return .{ .timestamp_ns = event.timestamp_ns, .session_id = event.session_id, .frame_id = event.frame_id, .level = event.level, .category = event.category, .message = message, .fields = fields };
}

fn freeField(allocator: std.mem.Allocator, field: Field) void {
    allocator.free(field.key);
    switch (field.value) {
        .string => |value| allocator.free(value),
        else => {},
    }
}

fn freeEvent(allocator: std.mem.Allocator, event: Event) void {
    allocator.free(event.message);
    for (event.fields) |field| freeField(allocator, field);
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

/// Parses explicit controls; unknown values are errors, never a silent filter.
/// A null result means logging is disabled before clock reads or allocations.
pub fn parseLevel(value: []const u8) !?Level {
    if (std.mem.eql(u8, value, "off")) return null;
    return std.meta.stringToEnum(Level, value) orelse error.InvalidLogLevel;
}

pub fn parseCategories(value: []const u8) !u32 {
    if (std.mem.eql(u8, value, "all")) return std.math.maxInt(u32);
    var mask: u32 = 0;
    var parts = std.mem.splitScalar(u8, value, ',');
    while (parts.next()) |part| {
        const category = std.meta.stringToEnum(Category, part) orelse return error.InvalidLogCategory;
        mask |= @as(u32, 1) << @intCast(@intFromEnum(category));
    }
    return mask;
}

/// Whole-record, append-only rotation. Owns its directory and current file;
/// name is a borrowed basename. Only that exact name and numbered archives
/// are touched. Callers serialize access; this is not a concurrent log sink.
pub const RotatingFile = struct {
    dir: std.fs.Dir,
    lock_file: std.fs.File,
    name: []const u8,
    max_bytes: u64,
    archives: u8,
    file: ?std.fs.File = null,
    bytes: u64 = 0,
    rotations: u64 = 0,
    discarded_bytes: u64 = 0,

    pub fn init(path: []const u8, name: []const u8, max_bytes: u64, archives: u8) !RotatingFile {
        if (!validKey(name) or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or max_bytes == 0 or archives == 0 or archives > 8) return error.InvalidLogLimits;
        var dir = try std.fs.cwd().openDir(path, .{});
        errdefer dir.close();
        var buffer: [96]u8 = undefined;
        const lock_name = try std.fmt.bufPrint(&buffer, "{s}.lock", .{name});
        var target: [std.fs.max_path_bytes]u8 = undefined;
        if (dir.readLink(lock_name, &target)) |_| return error.InvalidLogFile else |err| switch (err) {
            error.FileNotFound, error.NotLink => {},
            else => return err,
        }
        const lock_file = try dir.createFile(lock_name, .{ .truncate = false });
        errdefer lock_file.close();
        if (!try lock_file.tryLock(.exclusive)) return error.LogBusy;
        return .{ .dir = dir, .lock_file = lock_file, .name = name, .max_bytes = max_bytes, .archives = archives };
    }

    pub fn deinit(self: *RotatingFile) void {
        if (self.file) |file| file.close();
        self.lock_file.unlock();
        self.lock_file.close();
        self.dir.close();
        self.* = undefined;
    }

    pub fn append(self: *RotatingFile, record: []const u8) !void {
        if (record.len > self.max_bytes) return error.LogRecordTooLarge;
        if (self.file == null) {
            try self.requireRegular(self.name);
            const file = try self.dir.createFile(self.name, .{ .truncate = false, .read = true });
            errdefer file.close();
            self.discarded_bytes +|= try self.trimOversized(file);
            // Apply the same limit to archives left by older versions.
            var buffer: [96]u8 = undefined;
            for (1..@as(usize, self.archives) + 1) |index| {
                const name = try self.archiveName(&buffer, @intCast(index));
                try self.requireRegular(name);
                const archive = self.dir.openFile(name, .{ .mode = .read_write }) catch |err| switch (err) {
                    error.FileNotFound => continue,
                    else => return err,
                };
                defer archive.close();
                self.discarded_bytes +|= try self.trimOversized(archive);
            }
            self.bytes = try file.getEndPos();
            try file.seekFromEnd(0);
            self.file = file;
        }
        if (self.bytes > self.max_bytes - record.len) try self.rotate();
        try self.file.?.writeAll(record);
        self.bytes += record.len;
    }

    fn trimOversized(self: *RotatingFile, file: std.fs.File) !u64 {
        const end = try file.getEndPos();
        if (end <= self.max_bytes) return 0;
        var start = end - self.max_bytes;
        var buffer: [4096]u8 = undefined;
        // Retain only complete newline-delimited records from the tail.
        _ = try file.preadAll(buffer[0..1], start - 1);
        if (buffer[0] != '\n') {
            while (start < end) {
                const length = try file.preadAll(buffer[0..@intCast(@min(buffer.len, end - start))], start);
                if (length == 0) return error.UnexpectedEndOfFile;
                if (std.mem.indexOfScalar(u8, buffer[0..length], '\n')) |newline| {
                    start += newline + 1;
                    break;
                }
                start += length;
            }
        }
        var source = start;
        var destination: u64 = 0;
        while (source < end) {
            const length = try file.preadAll(buffer[0..@intCast(@min(buffer.len, end - source))], source);
            if (length == 0) return error.UnexpectedEndOfFile;
            try file.pwriteAll(buffer[0..length], destination);
            source += length;
            destination += length;
        }
        try file.setEndPos(destination);
        return start;
    }

    fn requireRegular(self: *RotatingFile, name: []const u8) !void {
        // lstat semantics: never follow a caller-created symlink when rotating.
        var target: [std.fs.max_path_bytes]u8 = undefined;
        if (self.dir.readLink(name, &target)) |_| return error.InvalidLogFile else |err| switch (err) {
            error.NotLink => {},
            error.FileNotFound => return,
            else => return err,
        }
        const info = try self.dir.statFile(name);
        if (info.kind != .file) return error.InvalidLogFile;
    }

    fn archiveName(self: *const RotatingFile, buffer: []u8, index: u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "{s}.{d}", .{ self.name, index });
    }

    fn rotate(self: *RotatingFile) !void {
        // Validate the entire set before changing any files.
        var buffer: [96]u8 = undefined;
        for (1..@as(usize, self.archives) + 1) |index| try self.requireRegular(try self.archiveName(&buffer, @intCast(index)));
        if (self.file) |file| file.close();
        self.file = null;
        var index = self.archives;
        while (index > 1) : (index -= 1) {
            var source: [96]u8 = undefined;
            const from = try self.archiveName(&source, index - 1);
            const to = try self.archiveName(&buffer, index);
            const overwritten = if (index == self.archives) (self.dir.statFile(to) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            }) else null;
            self.dir.rename(from, to) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            if (overwritten) |info| self.discarded_bytes +|= info.size;
        }
        const oldest = try self.archiveName(&buffer, 1);
        const overwritten = if (self.archives == 1) (self.dir.statFile(oldest) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        }) else null;
        try self.dir.rename(self.name, oldest);
        if (overwritten) |info| self.discarded_bytes +|= info.size;
        self.file = try self.dir.createFile(self.name, .{ .exclusive = true });
        self.bytes = 0;
        self.rotations +|= 1;
    }
};

test "log filters reject typos and support explicit off" {
    try std.testing.expectEqual(@as(?Level, null), try parseLevel("off"));
    try std.testing.expectEqual(Level.debug, (try parseLevel("debug")).?);
    try std.testing.expectError(error.InvalidLogLevel, parseLevel("verbose"));
    try std.testing.expectError(error.InvalidLogCategory, parseCategories("render,"));
    const mask = try parseCategories("render,assets");
    try std.testing.expectEqual((@as(u32, 1) << @intFromEnum(Category.render)) | (@as(u32, 1) << @intFromEnum(Category.assets)), mask);
}

fn ringAllocationFailures(allocator: std.mem.Allocator) !void {
    var ring = Ring.init(allocator, 1, .{});
    defer ring.deinit();
    const first: Event = .{ .timestamp_ns = 1, .session_id = 2, .level = .info, .category = .engine, .message = "first", .fields = &.{.{ .key = "name", .value = .{ .string = "owned" } }} };
    try ring.append(first);
    var second = first;
    second.message = "second";
    second.fields = &.{ .{ .key = "a", .value = .{ .string = "one" } }, .{ .key = "b", .value = .{ .string = "two" } } };
    ring.append(second) catch |err| {
        try std.testing.expectEqualStrings("first", ring.items()[0].message);
        try std.testing.expectEqual(@as(u64, 0), ring.dropped_events);
        return err;
    };
    try std.testing.expectEqualStrings("second", ring.items()[0].message);
    try std.testing.expectEqual(@as(u64, 1), ring.dropped_events);
}

test "event ring owns strings and rolls back every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, ringAllocationFailures, .{});
}

test "log rotation bounds whole records and leaves unrelated files alone" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    try temp.dir.writeFile(.{ .sub_path = "unrelated", .data = "keep" });
    var file = try RotatingFile.init(root, "events.jsonl", 8, 2);
    defer file.deinit();
    for ([_][]const u8{ "one\n", "two\n", "tri\n", "for\n", "fiv\n", "six\n", "sev\n" }) |line| try file.append(line);
    try std.testing.expectEqual(@as(u64, 3), file.rotations);
    try std.testing.expectEqual(@as(u64, 8), file.discarded_bytes);
    inline for (.{ "events.jsonl", "events.jsonl.1", "events.jsonl.2" }) |name| {
        const contents = try temp.dir.readFileAlloc(std.testing.allocator, name, 8);
        defer std.testing.allocator.free(contents);
        try std.testing.expect(contents.len <= 8 and std.mem.endsWith(u8, contents, "\n"));
    }
    try std.testing.expectError(error.FileNotFound, temp.dir.access("events.jsonl.3", .{}));
    try std.testing.expectError(error.LogRecordTooLarge, file.append("too large"));
    try temp.dir.access("unrelated", .{});
    // A caller-owned directory with a log-like name is never deleted.
    try temp.dir.makeDir("other.log.1");
    var blocked = try RotatingFile.init(root, "other.log", 2, 1);
    defer blocked.deinit();
    try std.testing.expectError(error.InvalidLogFile, blocked.append("a\n"));
    try temp.dir.access("other.log.1", .{});
}

test "rotation bounds existing oversized logs and refuses dangling symlinks" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    try temp.dir.writeFile(.{ .sub_path = "old.log", .data = "zero\none\ntwo\n" });
    var file = try RotatingFile.init(root, "old.log", 8, 1);
    defer file.deinit();
    try file.append("new\n");
    try std.testing.expectEqual(@as(u64, 5), file.discarded_bytes);
    const previous = try temp.dir.readFileAlloc(std.testing.allocator, "old.log.1", 8);
    defer std.testing.allocator.free(previous);
    try std.testing.expectEqualStrings("one\ntwo\n", previous);
    if (@import("builtin").os.tag != .windows) {
        try temp.dir.symLink("absent-target", "link.log", .{});
        var linked = try RotatingFile.init(root, "link.log", 8, 1);
        defer linked.deinit();
        try std.testing.expectError(error.InvalidLogFile, linked.append("x\n"));
        try std.testing.expectError(error.FileNotFound, temp.dir.access("absent-target", .{}));
    }
}

/// Borrow a valid UTF-8 prefix within a byte budget. Hosts use this before
/// formatting bounded records; the generic Event validator stays compatible.
pub fn boundedText(text: []const u8, limit: usize) struct { value: []const u8, truncated: bool } {
    var end = @min(text.len, limit);
    while (end > 0 and !std.unicode.utf8ValidateSlice(text[0..end])) : (end -= 1) {}
    return .{ .value = text[0..end], .truncated = end != text.len };
}

test "bounded host text preserves UTF-8 and reports omitted bytes" {
    const clipped = boundedText("a✓b", 3);
    try std.testing.expectEqualStrings("a", clipped.value);
    try std.testing.expect(clipped.truncated);
    try std.testing.expectEqualStrings("a✓", boundedText("a✓b", 4).value);
    try std.testing.expectEqualStrings("valid", boundedText("valid\xfftail", 64).value);
}

test "concurrent sessions cannot interleave or rotate the same log" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    {
        var first = try RotatingFile.init(root, "shared.jsonl", 1024, 1);
        defer first.deinit();
        try std.testing.expectError(error.LogBusy, RotatingFile.init(root, "shared.jsonl", 1024, 1));
        try first.append("first\n");
    }
    var next = try RotatingFile.init(root, "shared.jsonl", 1024, 1);
    defer next.deinit();
    try next.append("next\n");
    const contents = try temp.dir.readFileAlloc(std.testing.allocator, "shared.jsonl", 1024);
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("first\nnext\n", contents);
}
