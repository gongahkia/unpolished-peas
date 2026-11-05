const std = @import("std");
pub const PhysicalKey = @import("physical_key.zig").PhysicalKey;

pub const TextInput = struct { enabled: bool = false };
pub const Kind = enum(u8) { key_down, key_up, text_commit, composition_start, composition_update, composition_end, composition_cancel, text_started, text_stopped };
pub const Event = struct {
    kind: Kind,
    key: ?PhysicalKey = null,
    repeat: bool = false,
    text_offset: u16 = 0,
    text_len: u16 = 0,
    selection_start: i16 = -1,
    selection_length: i16 = -1,
};

pub const State = struct {
    pub const max_events = 32;
    pub const max_text_bytes = 1024;
    pub const wire_header_bytes = 104;
    pub const wire_event_bytes = 12;
    pub const max_wire_bytes = wire_header_bytes + max_events * wire_event_bytes + max_text_bytes;

    down: [256]bool = .{false} ** 256,
    pressed: [256]bool = .{false} ** 256,
    released: [256]bool = .{false} ** 256,
    active: bool = false,
    composing: bool = false,
    overflow: bool = false,
    event_count: u8 = 0,
    text_len: u16 = 0,
    events: [max_events]Event = .{Event{ .kind = .key_down }} ** max_events,
    text: [max_text_bytes]u8 = .{0} ** max_text_bytes,

    pub fn eventSlice(self: *const State) []const Event {
        return self.events[0..self.event_count];
    }

    pub fn eventText(self: *const State, event: Event) []const u8 {
        return self.text[event.text_offset..][0..event.text_len];
    }

    pub fn append(self: *State, event: Event, text: []const u8) !void {
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        if (self.event_count == max_events or text.len > max_text_bytes - self.text_len) {
            self.overflow = true;
            return error.InputOverflow;
        }
        var copy = event;
        copy.text_offset = self.text_len;
        copy.text_len = @intCast(text.len);
        try validateEvent(copy, text);
        @memcpy(self.text[self.text_len..][0..text.len], text);
        self.text_len += @intCast(text.len);
        self.events[self.event_count] = copy;
        self.event_count += 1;
    }

    pub fn setKey(self: *State, key: PhysicalKey, down: bool, repeat: bool) void {
        const index = @intFromEnum(key);
        const prior = self.down[index];
        if (prior == down and !(down and repeat)) return;
        self.down[index] = down;
        if (prior != down) {
            if (down) self.pressed[index] = true else self.released[index] = true;
        }
        self.append(.{ .kind = if (down) .key_down else .key_up, .key = key, .repeat = repeat and prior and down }, "") catch {};
    }

    pub fn setActive(self: *State, enabled: bool) void {
        if (self.active == enabled) return;
        if (!enabled) self.cancelComposition();
        self.active = enabled;
        self.append(.{ .kind = if (enabled) .text_started else .text_stopped }, "") catch {};
    }

    pub fn commit(self: *State, text: []const u8) !void {
        if (!self.active) return error.TextInputInactive;
        try self.append(.{ .kind = .text_commit }, text);
    }

    pub fn composition(self: *State, text: []const u8, start: i16, length: i16) !void {
        if (!self.active) return error.TextInputInactive;
        // Validate before changing the composition lifecycle.
        try validateEvent(.{ .kind = .composition_update, .selection_start = start, .selection_length = length }, text);
        if (!self.composing) {
            self.composing = true;
            self.append(.{ .kind = .composition_start }, "") catch {};
        }
        try self.append(.{ .kind = .composition_update, .selection_start = start, .selection_length = length }, text);
    }

    pub fn endComposition(self: *State) void {
        if (!self.composing) return;
        self.composing = false;
        self.append(.{ .kind = .composition_end }, "") catch {};
    }

    pub fn cancelComposition(self: *State) void {
        if (!self.composing) return;
        self.composing = false;
        self.append(.{ .kind = .composition_cancel }, "") catch {};
    }

    pub fn releaseAll(self: *State) void {
        inline for (@typeInfo(PhysicalKey).@"enum".fields) |field| {
            if (self.down[field.value]) self.setKey(@enumFromInt(field.value), false, false);
        }
        self.cancelComposition();
    }

    pub fn clearTransient(self: *State) void {
        @memset(&self.pressed, false);
        @memset(&self.released, false);
        self.event_count = 0;
        self.text_len = 0;
        self.overflow = false;
        self.events = .{Event{ .kind = .key_down }} ** max_events;
        @memset(&self.text, 0);
    }

    pub fn merge(self: *State, newer: State) void {
        self.down = newer.down;
        for (&self.pressed, newer.pressed) |*v, n| v.* = v.* or n;
        for (&self.released, newer.released) |*v, n| v.* = v.* or n;
        self.active = newer.active;
        self.composing = newer.composing;
        self.overflow = self.overflow or newer.overflow;
        for (newer.eventSlice()) |event| self.append(event, newer.eventText(event)) catch {};
    }

    pub fn isEmpty(self: *const State) bool {
        if (self.active or self.composing or self.overflow or self.event_count != 0 or self.text_len != 0) return false;
        for (self.down, self.pressed, self.released) |d, p, r| if (d or p or r) return false;
        return true;
    }

    pub fn valid(self: *const State) bool {
        if (self.event_count > max_events or self.text_len > max_text_bytes or (self.composing and !self.active)) return false;
        for (self.down, self.pressed, self.released, 0..) |d, p, r, index| {
            if (d or p or r) _ = std.meta.intToEnum(PhysicalKey, index) catch return false;
        }
        var used: usize = 0;
        for (self.eventSlice()) |event| {
            if (event.text_offset != used or event.text_len > self.text_len - used) return false;
            validateEvent(event, self.eventText(event)) catch return false;
            used += event.text_len;
        }
        return used == self.text_len;
    }

    pub fn encodedSize(self: *const State) usize {
        return wire_header_bytes + @as(usize, self.event_count) * wire_event_bytes + self.text_len;
    }

    pub fn encode(self: *const State, bytes: []u8) !usize {
        if (!self.valid() or bytes.len < self.encodedSize()) return error.InvalidInputExtension;
        @memset(bytes, 0);
        for (0..256) |index| {
            const bit = @as(u8, 1) << @as(u3, @intCast(index % 8));
            if (self.down[index]) bytes[index / 8] |= bit;
            if (self.pressed[index]) bytes[32 + index / 8] |= bit;
            if (self.released[index]) bytes[64 + index / 8] |= bit;
        }
        bytes[96] = @intFromBool(self.active);
        bytes[97] = @intFromBool(self.composing);
        bytes[98] = @intFromBool(self.overflow);
        bytes[99] = self.event_count;
        std.mem.writeInt(u16, bytes[100..102], self.text_len, .little);
        for (self.eventSlice(), 0..) |event, index| {
            const offset = wire_header_bytes + index * wire_event_bytes;
            bytes[offset] = @intFromEnum(event.kind);
            bytes[offset + 1] = if (event.key) |key| @intFromEnum(key) else 0;
            bytes[offset + 2] = @intFromBool(event.repeat);
            std.mem.writeInt(u16, bytes[offset + 4 ..][0..2], event.text_offset, .little);
            std.mem.writeInt(u16, bytes[offset + 6 ..][0..2], event.text_len, .little);
            std.mem.writeInt(i16, bytes[offset + 8 ..][0..2], event.selection_start, .little);
            std.mem.writeInt(i16, bytes[offset + 10 ..][0..2], event.selection_length, .little);
        }
        const offset = wire_header_bytes + @as(usize, self.event_count) * wire_event_bytes;
        @memcpy(bytes[offset..][0..self.text_len], self.text[0..self.text_len]);
        return self.encodedSize();
    }

    pub fn decode(bytes: []const u8) !State {
        if (bytes.len < wire_header_bytes or bytes.len > max_wire_bytes) return error.InvalidInputExtension;
        var value = State{};
        for (0..256) |index| {
            const bit = @as(u8, 1) << @as(u3, @intCast(index % 8));
            value.down[index] = bytes[index / 8] & bit != 0;
            value.pressed[index] = bytes[32 + index / 8] & bit != 0;
            value.released[index] = bytes[64 + index / 8] & bit != 0;
        }
        if (bytes[96] > 1 or bytes[97] > 1 or bytes[98] > 1 or bytes[102] != 0 or bytes[103] != 0) return error.InvalidInputExtension;
        value.active = bytes[96] == 1;
        value.composing = bytes[97] == 1;
        value.overflow = bytes[98] == 1;
        value.event_count = bytes[99];
        value.text_len = std.mem.readInt(u16, bytes[100..102], .little);
        if (value.event_count > max_events or value.text_len > max_text_bytes or bytes.len != value.encodedSize()) return error.InvalidInputExtension;
        for (value.events[0..value.event_count], 0..) |*event, index| {
            const offset = wire_header_bytes + index * wire_event_bytes;
            if (bytes[offset + 2] > 1 or bytes[offset + 3] != 0) return error.InvalidInputExtension;
            event.* = .{
                .kind = std.meta.intToEnum(Kind, bytes[offset]) catch return error.InvalidInputExtension,
                .key = if (bytes[offset + 1] == 0) null else std.meta.intToEnum(PhysicalKey, bytes[offset + 1]) catch return error.InvalidInputExtension,
                .repeat = bytes[offset + 2] == 1,
                .text_offset = std.mem.readInt(u16, bytes[offset + 4 ..][0..2], .little),
                .text_len = std.mem.readInt(u16, bytes[offset + 6 ..][0..2], .little),
                .selection_start = std.mem.readInt(i16, bytes[offset + 8 ..][0..2], .little),
                .selection_length = std.mem.readInt(i16, bytes[offset + 10 ..][0..2], .little),
            };
        }
        const offset = wire_header_bytes + @as(usize, value.event_count) * wire_event_bytes;
        @memcpy(value.text[0..value.text_len], bytes[offset..]);
        if (!value.valid()) return error.InvalidInputExtension;
        return value;
    }
};

fn validateEvent(event: Event, text: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    const count = std.unicode.utf8CountCodepoints(text) catch return error.InvalidUtf8;
    const keyed = event.kind == .key_down or event.kind == .key_up;
    if ((event.key != null) != keyed or (event.repeat and event.kind != .key_down)) return error.InvalidInputEvent;
    const textual = event.kind == .text_commit or event.kind == .composition_update;
    if (!textual and text.len != 0) return error.InvalidInputEvent;
    if (event.kind != .composition_update) {
        if (event.selection_start != -1 or event.selection_length != -1) return error.InvalidInputEvent;
    } else if (event.selection_start != -1 or event.selection_length != -1) {
        if (event.selection_start < 0 or event.selection_length < 0 or @as(usize, @intCast(event.selection_start)) > count or @as(usize, @intCast(event.selection_length)) > count - @as(usize, @intCast(event.selection_start))) return error.InvalidInputEvent;
    }
}

test "bounded input rejects invalid UTF-8 and overflow atomically" {
    var state = State{};
    state.setActive(true);
    state.clearTransient();
    try std.testing.expectError(error.InvalidUtf8, state.commit(&.{0xff}));
    try std.testing.expectError(error.InvalidUtf8, state.composition(&.{ 0xc3, 0x28 }, -1, -1));
    try std.testing.expect(!state.composing);
    try std.testing.expectEqual(@as(u8, 0), state.event_count);
    try std.testing.expectError(error.InvalidInputEvent, state.composition("é", 2, 0));
    try std.testing.expect(!state.composing);
    state.setKey(.q, true, false);
    for (1..State.max_events) |_| state.setKey(.q, true, true);
    try std.testing.expectError(error.InputOverflow, state.commit("界"));
    try std.testing.expect(state.overflow);
    try std.testing.expectEqual(@as(u16, 0), state.text_len);
    state.clearTransient();
    var full: [State.max_text_bytes]u8 = .{'a'} ** State.max_text_bytes;
    try state.commit(&full);
    try std.testing.expectError(error.InputOverflow, state.commit("é"));
    try std.testing.expectEqual(@as(u16, State.max_text_bytes), state.text_len);
    try std.testing.expect(state.down[@intFromEnum(PhysicalKey.q)]);
}

test "input extension wire uses stable IDs and rejects malformed fields" {
    var state = State{};
    state.setActive(true);
    state.setKey(.q, true, false);
    try state.composition("é界", 1, 1);
    var bytes: [State.max_wire_bytes]u8 = undefined;
    const len = try state.encode(&bytes);
    try std.testing.expectEqual(@as(u8, 16), bytes[2]); // HID Q = 20.
    try std.testing.expectEqual(@as(u8, 1), bytes[96]);
    const parsed = try State.decode(bytes[0..len]);
    try std.testing.expectEqualDeep(state, parsed);
    bytes[0] = 1; // Unsupported physical key ID.
    try std.testing.expectError(error.InvalidInputExtension, State.decode(bytes[0..len]));
    bytes[0] = 0;
    bytes[96] = 2;
    try std.testing.expectError(error.InvalidInputExtension, State.decode(bytes[0..len]));
    bytes[96] = 1;
    bytes[len - 1] = 0xff;
    try std.testing.expectError(error.InvalidInputExtension, State.decode(bytes[0..len]));
    _ = try state.encode(&bytes);
    const text_offset = State.wire_header_bytes + @as(usize, state.event_count) * State.wire_event_bytes;
    bytes[text_offset] = 0xc3;
    bytes[text_offset + 1] = 0x28;
    try std.testing.expectError(error.InvalidInputExtension, State.decode(bytes[0..len]));
}
