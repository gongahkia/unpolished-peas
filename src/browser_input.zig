const std = @import("std");
const Input = @import("input.zig").Input;
const Gamepad = @import("input.zig").Gamepad;
const Key = @import("input.zig").Key;
const Vec2 = @import("math.zig").Vec2;

pub const abi_version: u32 = 1; // Legacy decoder fixture version.
pub const encode_version: u32 = 2;
pub const legacy_bytes: usize = 376;
pub const abi_bytes: usize = 1890;
pub const request_marker: u32 = 0x32515055;

/// Decodes the browser host's fixed input ABI into the same normalized input
/// snapshot used by native and headless simulation. The ABI itself contains no
/// browser object identity or timestamp.
pub fn decode(bytes: []const u8) !Input.Snapshot {
    if (bytes.len < legacy_bytes) return error.InvalidInputAbi;
    const version = readU32(bytes, 0);
    if (!((version == 1 and bytes.len == legacy_bytes) or (version == 2 and bytes.len == abi_bytes))) return error.InvalidInputAbi;
    var value = Input.Snapshot{};
    const flags = readU32(bytes, 4);
    try boolMaskInto(value.down[0..], readU32(bytes, 20));
    try boolMaskInto(value.pressed[0..], readU32(bytes, 24));
    try boolMaskInto(value.released[0..], readU32(bytes, 28));
    try boolMaskInto(value.pointer_down[0..], readU32(bytes, 32));
    try boolMaskInto(value.pointer_pressed[0..], readU32(bytes, 36));
    try boolMaskInto(value.pointer_released[0..], readU32(bytes, 40));
    value.pointer.window = .{ .x = readF32(bytes, 44), .y = readF32(bytes, 48) };
    value.pointer.framebuffer = .{ .x = readF32(bytes, 52), .y = readF32(bytes, 56) };
    const canvas: Vec2 = .{ .x = readF32(bytes, 60), .y = readF32(bytes, 64) };
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
        var gamepad = Gamepad{ .id = readI32(bytes, offset), .connected = connected };
        try boolMaskInto(gamepad.buttons[0..], readU32(bytes, offset + 8));
        try boolMaskInto(gamepad.pressed[0..], readU32(bytes, offset + 12));
        try boolMaskInto(gamepad.released[0..], readU32(bytes, offset + 16));
        for (&gamepad.axes, 0..) |*axis, axis_index| axis.* = readF32(bytes, offset + 20 + axis_index * 4);
        for (&gamepad.previous_axes, 0..) |*axis, axis_index| axis.* = readF32(bytes, offset + 44 + axis_index * 4);
        value.gamepads[index] = gamepad;
    }
    if (version == 2) {
        const len = std.mem.readInt(u16, bytes[376..378], .little);
        if (len > Input.Extended.max_wire_bytes) return error.InvalidInputAbi;
        value.extended = Input.Extended.decode(bytes[378..][0..len]) catch return error.InvalidInputAbi;
        for (bytes[378 + len ..]) |byte| if (byte != 0) return error.InvalidInputAbi;
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
    var bytes: [legacy_bytes]u8 = .{0} ** legacy_bytes;
    std.mem.writeInt(u32, bytes[0..4], abi_version, .little);
    std.mem.writeInt(u32, bytes[4..8], 4, .little);
    std.mem.writeInt(u32, bytes[20..24], 1 << @intFromEnum(Key.right), .little);
    std.mem.writeInt(u32, bytes[24..28], 1 << @intFromEnum(Key.right), .little);
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
    try std.testing.expect(snapshot.down[@intFromEnum(Key.right)]);
    try std.testing.expect(snapshot.pressed[@intFromEnum(Key.right)]);
    try std.testing.expect(snapshot.pointer.canvas != null);
    try std.testing.expectEqual(@as(f32, 7), snapshot.pointer.canvas.?.x);
    try std.testing.expect(snapshot.gamepads[0].?.wasPressed(.south));
    try std.testing.expectEqual(@as(f32, -0.5), snapshot.gamepads[0].?.axis(.left_x));
}

fn encodeMask(values: []const bool) u32 {
    var result: u32 = 0;
    for (values, 0..) |v, i| if (v) {
        result |= @as(u32, 1) << @intCast(i);
    };
    return result;
}
fn put(b: []u8, index: usize, value: u32) void {
    std.mem.writeInt(u32, b[index..][0..4], value, .little);
}
fn float(b: []u8, index: usize, value: f32) void {
    put(b, index, @bitCast(value));
}
/// Browser host state absent from Input.Snapshot; supplied explicitly by exporters.
pub const Metadata = struct {
    framebuffer_width: u32,
    framebuffer_height: u32,
    focused: bool,
    visible: bool,
    resize_epoch: u32 = 0,
};
/// Encodes ABI v2 without allocating. Controller slots compact in iteration order,
/// as in the host wire format; identities and edges are preserved. Output is
/// unspecified on error. Requires exactly abi_bytes of output storage.
pub fn encode(frame: Input.Snapshot, metadata: Metadata, b: []u8) !void {
    if (b.len != abi_bytes or !frame.isFinite()) return error.InvalidInputAbi;
    @memset(b, 0);
    put(b, 0, encode_version);
    put(b, 4, @as(u32, @intFromBool(metadata.focused)) | (@as(u32, @intFromBool(metadata.visible)) << 1) | (if (frame.pointer.canvas != null) @as(u32, 4) else 0));
    put(b, 8, metadata.resize_epoch);
    put(b, 12, metadata.framebuffer_width);
    put(b, 16, metadata.framebuffer_height);
    put(b, 20, encodeMask(&frame.down));
    put(b, 24, encodeMask(&frame.pressed));
    put(b, 28, encodeMask(&frame.released));
    put(b, 32, encodeMask(&frame.pointer_down));
    put(b, 36, encodeMask(&frame.pointer_pressed));
    put(b, 40, encodeMask(&frame.pointer_released));
    float(b, 44, frame.pointer.window.x);
    float(b, 48, frame.pointer.window.y);
    float(b, 52, frame.pointer.framebuffer.x);
    float(b, 56, frame.pointer.framebuffer.y);
    const p = frame.pointer.canvas orelse Vec2{};
    float(b, 60, p.x);
    float(b, 64, p.y);
    float(b, 68, frame.pointer.delta.x);
    float(b, 72, frame.pointer.delta.y);
    float(b, 76, frame.pointer.wheel.x);
    float(b, 80, frame.pointer.wheel.y);
    var count: usize = 0;
    for (frame.gamepads) |slot| if (slot) |pad| {
        const offset = 88 + count * 72;
        count += 1;
        put(b, offset, @bitCast(pad.id));
        put(b, offset + 4, @intFromBool(pad.connected));
        put(b, offset + 8, encodeMask(&pad.buttons));
        put(b, offset + 12, encodeMask(&pad.pressed));
        put(b, offset + 16, encodeMask(&pad.released));
        for (pad.axes, 0..) |axis, i| float(b, offset + 20 + i * 4, axis);
        for (pad.previous_axes, 0..) |axis, i| float(b, offset + 44 + i * 4, axis);
    };
    put(b, 84, @intCast(count));
    const length = try frame.extended.encode(b[378..]);
    std.mem.writeInt(u16, b[376..378], @intCast(length), .little);
}

test "encoder specifies wire fields and compacts sparse controllers" {
    var input = Input{};
    input.set(.right, true);
    input.pointer.canvas = .{ .x = 7, .y = 9 };
    input.gamepads[3] = .{ .id = -7, .connected = false };
    input.gamepads[3].?.axes[0] = -0.5;
    input.gamepads[3].?.previous_axes[0] = 0.25;
    var bytes: [abi_bytes]u8 = undefined;
    try encode(input.snapshot(), .{ .framebuffer_width = 640, .framebuffer_height = 360, .focused = false, .visible = true, .resize_epoch = 19 }, &bytes);
    try std.testing.expectEqual(@as(u32, 2), readU32(&bytes, 0));
    try std.testing.expectEqual(@as(u32, 6), readU32(&bytes, 4));
    try std.testing.expectEqual(@as(u32, 19), readU32(&bytes, 8));
    try std.testing.expectEqual(@as(u32, 640), readU32(&bytes, 12));
    try std.testing.expectEqual(@as(u32, 8), readU32(&bytes, 20));
    try std.testing.expectEqual(@as(u32, 8), readU32(&bytes, 24));
    try std.testing.expectEqual(@as(i32, -7), readI32(&bytes, 88));
    try std.testing.expectEqual(@as(f32, 0.25), readF32(&bytes, 132));
    const restored = try decode(&bytes);
    try std.testing.expectEqual(@as(i32, -7), restored.gamepads[0].?.id);
    try std.testing.expect(restored.gamepads[3] == null);
    try std.testing.expectError(error.InvalidInputAbi, encode(input.snapshot(), .{ .framebuffer_width = 1, .framebuffer_height = 1, .focused = true, .visible = true }, bytes[0..10]));
    input.pointer.window.x = std.math.nan(f32);
    try std.testing.expectError(error.InvalidInputAbi, encode(input.snapshot(), .{ .framebuffer_width = 1, .framebuffer_height = 1, .focused = true, .visible = true }, &bytes));
}
