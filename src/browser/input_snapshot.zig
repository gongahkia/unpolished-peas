const std = @import("std");
const up = @import("unpolished-peas");

pub const abi_version: u32 = 1;
pub const abi_bytes: usize = 376;

/// Browser-runtime-only fixed-tick buffering. Browser module roots cannot
/// import parent source files, so this mirrors the backend-private helper
/// without exposing it through Peas's public `Input` API.
pub fn TickBuffer(comptime Input: type) type {
    return struct {
        const Self = @This();

        pending: Input.Snapshot = .{},

        pub fn submit(self: *Self, state: Input) void {
            self.pending.merge(state.snapshot());
        }

        pub fn next(self: *Self) Input.Snapshot {
            const result = self.pending;
            self.pending.clearTransient();
            return result;
        }

        pub fn reset(self: *Self) void {
            self.* = .{};
        }
    };
}

/// Decodes the browser host's fixed input ABI into the same normalized input
/// snapshot used by native and headless simulation. The ABI itself contains no
/// browser object identity or timestamp.
pub fn decode(bytes: []const u8) !up.input.Input.Snapshot {
    if (bytes.len != abi_bytes or readU32(bytes, 0) != abi_version) return error.InvalidInputAbi;
    var value = up.input.Input.Snapshot{};
    const flags = readU32(bytes, 4);
    try boolMaskInto(value.down[0..], readU32(bytes, 20));
    try boolMaskInto(value.pressed[0..], readU32(bytes, 24));
    try boolMaskInto(value.released[0..], readU32(bytes, 28));
    try boolMaskInto(value.pointer_down[0..], readU32(bytes, 32));
    try boolMaskInto(value.pointer_pressed[0..], readU32(bytes, 36));
    try boolMaskInto(value.pointer_released[0..], readU32(bytes, 40));
    value.pointer.window = .{ .x = readF32(bytes, 44), .y = readF32(bytes, 48) };
    value.pointer.framebuffer = .{ .x = readF32(bytes, 52), .y = readF32(bytes, 56) };
    const canvas: up.core.Vec2 = .{ .x = readF32(bytes, 60), .y = readF32(bytes, 64) };
    value.pointer.canvas = if ((flags & 4) != 0) canvas else null;
    value.pointer.delta = .{ .x = readF32(bytes, 68), .y = readF32(bytes, 72) };
    value.pointer.wheel = .{ .x = readF32(bytes, 76), .y = readF32(bytes, 80) };
    const gamepad_count = readU32(bytes, 84);
    if (gamepad_count > value.gamepads.len) return error.InvalidInputAbi;
    for (0..gamepad_count) |index| {
        const offset = 88 + index * 72;
        const connected = switch (readU32(bytes, offset + 4)) {
            0 => false,
            1 => true,
            else => return error.InvalidInputAbi,
        };
        var gamepad = up.input.Gamepad{ .id = readI32(bytes, offset), .connected = connected };
        try boolMaskInto(gamepad.buttons[0..], readU32(bytes, offset + 8));
        try boolMaskInto(gamepad.pressed[0..], readU32(bytes, offset + 12));
        try boolMaskInto(gamepad.released[0..], readU32(bytes, offset + 16));
        for (&gamepad.axes, 0..) |*axis, axis_index| axis.* = readF32(bytes, offset + 20 + axis_index * 4);
        for (&gamepad.previous_axes, 0..) |*axis, axis_index| axis.* = readF32(bytes, offset + 44 + axis_index * 4);
        value.gamepads[index] = gamepad;
    }
    if (!value.isFinite()) return error.InvalidInputAbi;
    return value;
}

fn readU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn readI32(bytes: []const u8, offset: usize) i32 {
    return std.mem.readInt(i32, bytes[offset..][0..4], .little);
}

fn readF32(bytes: []const u8, offset: usize) f32 {
    return @bitCast(readU32(bytes, offset));
}

fn boolMaskInto(values: []bool, mask: u32) !void {
    const shift: u5 = @intCast(values.len);
    if (mask >> shift != 0) return error.InvalidInputAbi;
    for (values, 0..) |*value, index| value.* = (mask & (@as(u32, 1) << @intCast(index))) != 0;
}

test "browser input ABI decodes a complete normalized snapshot" {
    var bytes: [abi_bytes]u8 = .{0} ** abi_bytes;
    std.mem.writeInt(u32, bytes[0..4], abi_version, .little);
    std.mem.writeInt(u32, bytes[4..8], 4, .little);
    std.mem.writeInt(u32, bytes[20..24], 1 << @intFromEnum(up.input.Key.right), .little);
    std.mem.writeInt(u32, bytes[24..28], 1 << @intFromEnum(up.input.Key.right), .little);
    std.mem.writeInt(u32, bytes[32..36], 1, .little);
    std.mem.writeInt(u32, bytes[36..40], 1, .little);
    std.mem.writeInt(u32, bytes[84..88], 1, .little);
    std.mem.writeInt(i32, bytes[88..92], 12, .little);
    std.mem.writeInt(u32, bytes[92..96], 1, .little);
    std.mem.writeInt(u32, bytes[96..100], 1, .little);
    std.mem.writeInt(u32, bytes[100..104], 1, .little);
    std.mem.writeInt(u32, bytes[108..112], @bitCast(@as(f32, -0.5)), .little);
    std.mem.writeInt(u32, bytes[60..64], @bitCast(@as(f32, 7)), .little);
    std.mem.writeInt(u32, bytes[64..68], @bitCast(@as(f32, 9)), .little);
    const snapshot = try decode(&bytes);
    try std.testing.expect(snapshot.down[@intFromEnum(up.input.Key.right)]);
    try std.testing.expect(snapshot.pressed[@intFromEnum(up.input.Key.right)]);
    try std.testing.expect(snapshot.pointer.canvas != null);
    try std.testing.expectEqual(@as(f32, 7), snapshot.pointer.canvas.?.x);
    try std.testing.expect(snapshot.gamepads[0].?.wasPressed(.south));
    try std.testing.expectEqual(@as(f32, -0.5), snapshot.gamepads[0].?.axis(.left_x));
}
