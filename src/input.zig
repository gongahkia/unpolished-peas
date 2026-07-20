const std = @import("std");
const Vec2 = @import("math.zig").Vec2;
const keyboard_pointer_fixture = @embedFile("fixtures/input/keyboard-pointer-v1.json");

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

pub const PointerButton = enum(u8) {
    left,
    middle,
    right,
    back,
    forward,
};

const pointer_button_count = @typeInfo(PointerButton).@"enum".fields.len;

pub const GamepadButton = enum(u8) { south, east, west, north, back, start, left_stick, right_stick, left_shoulder, right_shoulder, dpad_up, dpad_down, dpad_left, dpad_right };
pub const GamepadAxis = enum(u8) { left_x, left_y, right_x, right_y, left_trigger, right_trigger };
const gamepad_button_count = @typeInfo(GamepadButton).@"enum".fields.len;
const gamepad_axis_count = @typeInfo(GamepadAxis).@"enum".fields.len;

pub const Gamepad = struct {
    id: i32,
    connected: bool = true,
    buttons: [gamepad_button_count]bool = .{false} ** gamepad_button_count,
    pressed: [gamepad_button_count]bool = .{false} ** gamepad_button_count,
    released: [gamepad_button_count]bool = .{false} ** gamepad_button_count,
    axes: [gamepad_axis_count]f32 = .{0} ** gamepad_axis_count,
    previous_axes: [gamepad_axis_count]f32 = .{0} ** gamepad_axis_count,

    pub fn button(self: Gamepad, value: GamepadButton) bool {
        return self.buttons[@intFromEnum(value)];
    }

    pub fn wasPressed(self: Gamepad, value: GamepadButton) bool {
        return self.pressed[@intFromEnum(value)];
    }

    pub fn wasReleased(self: Gamepad, value: GamepadButton) bool {
        return self.released[@intFromEnum(value)];
    }

    pub fn axis(self: Gamepad, value: GamepadAxis) f32 {
        return self.axes[@intFromEnum(value)];
    }

    pub fn previousAxis(self: Gamepad, value: GamepadAxis) f32 {
        return self.previous_axes[@intFromEnum(value)];
    }
};

pub const Pointer = struct {
    window: Vec2 = .{},
    framebuffer: Vec2 = .{},
    canvas: ?Vec2 = null,
    delta: Vec2 = .{},
    wheel: Vec2 = .{},
};

pub const Input = struct {
    down: [key_count]bool = .{false} ** key_count,
    pressed: [key_count]bool = .{false} ** key_count,
    released: [key_count]bool = .{false} ** key_count,
    pointer: Pointer = .{},
    pointer_down: [pointer_button_count]bool = .{false} ** pointer_button_count,
    pointer_pressed: [pointer_button_count]bool = .{false} ** pointer_button_count,
    pointer_released: [pointer_button_count]bool = .{false} ** pointer_button_count,
    gamepads: [4]?Gamepad = .{null} ** 4,

    pub fn beginFrame(self: *Input) void {
        @memset(self.pressed[0..], false);
        @memset(self.released[0..], false);
        @memset(self.pointer_pressed[0..], false);
        @memset(self.pointer_released[0..], false);
        self.pointer.delta = .{};
        self.pointer.wheel = .{};
        for (&self.gamepads) |*slot| if (slot.*) |*pad| {
            @memset(pad.pressed[0..], false);
            @memset(pad.released[0..], false);
            pad.previous_axes = pad.axes;
        };
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

    pub fn setPointerPosition(self: *Input, window: Vec2, framebuffer: Vec2, canvas: ?Vec2) void {
        self.pointer.delta = framebuffer.sub(self.pointer.framebuffer);
        self.pointer.window = window;
        self.pointer.framebuffer = framebuffer;
        self.pointer.canvas = canvas;
    }

    pub fn addPointerWheel(self: *Input, delta: Vec2) void {
        self.pointer.wheel = self.pointer.wheel.add(delta);
    }

    pub fn setPointerButton(self: *Input, button: PointerButton, is_down: bool) void {
        const index = @intFromEnum(button);
        if (self.pointer_down[index] == is_down) return;
        self.pointer_down[index] = is_down;
        if (is_down) self.pointer_pressed[index] = true else self.pointer_released[index] = true;
    }

    pub fn releaseAll(self: *Input) void {
        for (self.down, 0..) |is_down, index| if (is_down) self.set(@enumFromInt(@as(u8, @intCast(index))), false);
        for (self.pointer_down, 0..) |is_down, index| if (is_down) self.setPointerButton(@enumFromInt(@as(u8, @intCast(index))), false);
    }

    pub fn pointerIsDown(self: Input, button: PointerButton) bool {
        return self.pointer_down[@intFromEnum(button)];
    }

    pub fn pointerWasPressed(self: Input, button: PointerButton) bool {
        return self.pointer_pressed[@intFromEnum(button)];
    }

    pub fn pointerWasReleased(self: Input, button: PointerButton) bool {
        return self.pointer_released[@intFromEnum(button)];
    }

    pub fn addGamepad(self: *Input, id: i32) bool {
        for (&self.gamepads) |*slot| if (slot.*) |pad| if (pad.id == id) return false;
        for (&self.gamepads) |*slot| if (slot.* == null) {
            slot.* = .{ .id = id };
            return true;
        };
        return false;
    }
    pub fn removeGamepad(self: *Input, id: i32) bool {
        for (&self.gamepads) |*slot| if (slot.*) |pad| if (pad.id == id) {
            slot.* = null;
            return true;
        };
        return false;
    }
    pub fn gamepad(self: Input, id: i32) ?Gamepad {
        for (self.gamepads) |slot| if (slot) |pad| if (pad.id == id) return pad;
        return null;
    }
    pub fn setGamepadButton(self: *Input, id: i32, button: GamepadButton, down: bool) void {
        for (&self.gamepads) |*slot| if (slot.*) |*pad| if (pad.id == id) {
            const index = @intFromEnum(button);
            if (pad.buttons[index] == down) return;
            pad.buttons[index] = down;
            if (down) pad.pressed[index] = true else pad.released[index] = true;
            return;
        };
    }
    pub fn setGamepadAxis(self: *Input, id: i32, axis: GamepadAxis, value: f32, dead_zone: f32) void {
        for (&self.gamepads) |*slot| if (slot.*) |*pad| if (pad.id == id) {
            pad.axes[@intFromEnum(axis)] = if (@abs(value) < dead_zone) 0 else value;
            return;
        };
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

test "pointer records mapped coordinates and edges" {
    var input = Input{};
    input.setPointerPosition(.{ .x = 10, .y = 20 }, .{ .x = 20, .y = 40 }, .{ .x = 5, .y = 10 });
    input.setPointerButton(.left, true);
    input.addPointerWheel(.{ .y = -1 });
    try std.testing.expectEqual(Vec2.init(20, 40), input.pointer.framebuffer);
    try std.testing.expect(input.pointerWasPressed(.left));
    try std.testing.expectEqual(@as(f32, -1), input.pointer.wheel.y);
    input.beginFrame();
    try std.testing.expectEqual(Vec2.zero, input.pointer.delta);
    try std.testing.expect(!input.pointerWasPressed(.left));
}

test "shared keyboard pointer fixture releases held input on focus loss" {
    const Fixture = struct {
        schema_version: u32,
        key: []const u8,
        pointer_button: []const u8,
        window: [2]f32,
        framebuffer: [2]f32,
        canvas: [2]f32,
    };
    var parsed = try std.json.parseFromSlice(Fixture, std.testing.allocator, keyboard_pointer_fixture, .{});
    defer parsed.deinit();
    const fixture = parsed.value;
    try std.testing.expectEqual(@as(u32, 1), fixture.schema_version);
    const key: Key = if (std.mem.eql(u8, fixture.key, "up")) .up else return error.InvalidInputFixture;
    const button: PointerButton = if (std.mem.eql(u8, fixture.pointer_button, "left")) .left else return error.InvalidInputFixture;
    var input = Input{};
    input.set(key, true);
    input.setPointerPosition(.{ .x = fixture.window[0], .y = fixture.window[1] }, .{ .x = fixture.framebuffer[0], .y = fixture.framebuffer[1] }, .{ .x = fixture.canvas[0], .y = fixture.canvas[1] });
    input.setPointerButton(button, true);
    try std.testing.expect(input.isDown(key));
    try std.testing.expect(input.pointerIsDown(button));
    try std.testing.expectEqual(Vec2.init(fixture.canvas[0], fixture.canvas[1]), input.pointer.canvas.?);
    input.beginFrame();
    input.releaseAll();
    try std.testing.expect(!input.isDown(key));
    try std.testing.expect(!input.pointerIsDown(button));
    try std.testing.expect(input.wasReleased(key));
    try std.testing.expect(input.pointerWasReleased(button));
}

test "gamepad add remove and dead-zone transitions" {
    var input = Input{};
    try std.testing.expect(input.addGamepad(7));
    try std.testing.expect(!input.addGamepad(7));
    input.setGamepadButton(7, .south, true);
    input.setGamepadAxis(7, .left_x, 0.1, 0.2);
    try std.testing.expect((input.gamepad(7).?).button(.south));
    try std.testing.expect((input.gamepad(7).?).wasPressed(.south));
    try std.testing.expectEqual(@as(f32, 0), (input.gamepad(7).?).axis(.left_x));
    input.setGamepadAxis(7, .left_x, -0.75, 0.2);
    try std.testing.expectEqual(@as(f32, -0.75), (input.gamepad(7).?).axis(.left_x));
    input.beginFrame();
    input.setGamepadButton(7, .south, false);
    try std.testing.expect((input.gamepad(7).?).wasReleased(.south));
    try std.testing.expectEqual(@as(f32, -0.75), (input.gamepad(7).?).previousAxis(.left_x));
    try std.testing.expect(input.removeGamepad(7));
    try std.testing.expect(input.gamepad(7) == null);
}
