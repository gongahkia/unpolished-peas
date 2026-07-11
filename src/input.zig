const std = @import("std");

pub const Key = enum(u8) {
    up,
    down,
    left,
    right,
    action,
    cancel,
    start,
    select,
    debug,
    screenshot,
};

const key_count = @typeInfo(Key).@"enum".fields.len;

pub const Input = struct {
    down: [key_count]bool = .{false} ** key_count,
    pressed: [key_count]bool = .{false} ** key_count,
    released: [key_count]bool = .{false} ** key_count,

    pub fn beginFrame(self: *Input) void {
        @memset(self.pressed[0..], false);
        @memset(self.released[0..], false);
    }

    pub fn set(self: *Input, key: Key, is_down: bool) void {
        const i = @intFromEnum(key);
        if (self.down[i] == is_down) return;
        self.down[i] = is_down;
        if (is_down) {
            self.pressed[i] = true;
        } else {
            self.released[i] = true;
        }
    }

    pub fn isDown(self: Input, key: Key) bool {
        return self.down[@intFromEnum(key)];
    }

    pub fn wasPressed(self: Input, key: Key) bool {
        return self.pressed[@intFromEnum(key)];
    }

    pub fn wasReleased(self: Input, key: Key) bool {
        return self.released[@intFromEnum(key)];
    }
};

test "input edges" {
    var input = Input{};
    input.set(.action, true);
    try std.testing.expect(input.isDown(.action));
    try std.testing.expect(input.wasPressed(.action));
    input.beginFrame();
    try std.testing.expect(!input.wasPressed(.action));
    input.set(.action, false);
    try std.testing.expect(input.wasReleased(.action));
}
