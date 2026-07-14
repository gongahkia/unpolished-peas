const std = @import("std");
const CameraCanvas = @import("camera_canvas.zig").CameraCanvas;
const Canvas = @import("canvas.zig").Canvas;
const Color = @import("color.zig").Color;
const Input = @import("input.zig").Input;
const Rect = @import("math.zig").Rect;
const Vec2 = @import("math.zig").Vec2;

pub const Id = u64;

pub const State = struct {
    focus: ?Id = null,
};

pub const Layout = struct {
    cursor: Vec2,
    width: f32,
    row_height: f32 = 12,
    gap: f32 = 2,

    pub fn next(self: *Layout) Rect {
        const rect = Rect.init(self.cursor.x, self.cursor.y, self.width, self.row_height);
        self.cursor.y += self.row_height + self.gap;
        return rect;
    }
};

pub const Style = struct {
    idle: Color = Color.rgb(42, 50, 66),
    hovered: Color = Color.rgb(58, 72, 94),
    focused: Color = Color.rgb(91, 123, 171),
    text: Color = Color.white,
    toggle_on: Color = Color.rgb(54, 126, 91),
};

pub const Response = struct {
    id: Id,
    rect: Rect,
    hovered: bool,
    focused: bool,
    pressed: bool,
};

pub const Surface = union(enum) {
    hud: *Canvas,
    world: CameraCanvas,

    fn pointer(self: Surface, input: *const Input) ?Vec2 {
        const point = input.pointer.canvas orelse return null;
        return switch (self) {
            .hud => point,
            .world => |canvas| canvas.camera.canvasToWorld(point, canvas.canvas_size),
        };
    }

    fn fillRect(self: Surface, rect: Rect, color: Color) void {
        switch (self) {
            .hud => |canvas| canvas.fillRect(floorToI32(rect.x), floorToI32(rect.y), ceilToI32(rect.w), ceilToI32(rect.h), color),
            .world => |canvas| canvas.fillRect(rect, color),
        }
    }

    fn strokeRect(self: Surface, rect: Rect, color: Color) void {
        switch (self) {
            .hud => |canvas| canvas.strokeRect(floorToI32(rect.x), floorToI32(rect.y), ceilToI32(rect.w), ceilToI32(rect.h), color),
            .world => |canvas| canvas.strokeRect(rect, color),
        }
    }

    fn text(self: Surface, value: []const u8, position: Vec2, color: Color) void {
        switch (self) {
            .hud => |canvas| canvas.drawText(value, floorToI32(position.x), floorToI32(position.y), color),
            .world => |canvas| canvas.drawText(value, position, color),
        }
    }
};

const Navigation = enum { previous, next };

pub const Frame = struct {
    state: *State,
    input: *const Input,
    surface: Surface,
    layout: Layout,
    style: Style = .{},
    navigation: ?Navigation,
    navigation_consumed: bool = false,
    first: ?Id = null,
    previous: ?Id = null,
    found_focus: bool = false,

    pub fn begin(state: *State, input: *const Input, surface: Surface, layout: Layout) Frame {
        return .{
            .state = state,
            .input = input,
            .surface = surface,
            .layout = layout,
            .navigation = navigation(input),
        };
    }

    pub fn label(self: *Frame, value: []const u8) void {
        const rect = self.layout.next();
        self.surface.text(value, .{ .x = rect.x, .y = rect.y + 2 }, self.style.text);
    }

    pub fn button(self: *Frame, widget_id: Id, label_text: []const u8) Response {
        return self.buttonAt(widget_id, self.layout.next(), label_text);
    }

    pub fn buttonLabel(self: *Frame, label_text: []const u8) Response {
        return self.button(id(label_text), label_text);
    }

    pub fn buttonAt(self: *Frame, widget_id: Id, rect: Rect, label_text: []const u8) Response {
        if (self.first == null) self.first = widget_id;
        const was_focused = self.state.focus != null and self.state.focus.? == widget_id;
        if (was_focused) self.found_focus = true;
        if (self.state.focus == null) self.state.focus = widget_id;
        self.applyNavigation(widget_id, was_focused);
        const hovered = if (self.surface.pointer(self.input)) |point| rect.contains(point) else false;
        if (hovered and self.input.pointerWasPressed(.left)) self.state.focus = widget_id;
        const focused = self.state.focus.? == widget_id;
        const pressed = (hovered and self.input.pointerWasPressed(.left)) or (focused and activate(self.input));
        self.drawButton(rect, label_text, hovered, focused, false);
        self.previous = widget_id;
        return .{ .id = widget_id, .rect = rect, .hovered = hovered, .focused = focused, .pressed = pressed };
    }

    pub fn toggle(self: *Frame, widget_id: Id, label_text: []const u8, value: *bool) Response {
        const response = self.button(widget_id, label_text);
        if (response.pressed) value.* = !value.*;
        self.drawButton(response.rect, label_text, response.hovered, response.focused, value.*);
        return response;
    }

    pub fn end(self: *Frame) void {
        if (self.first == null) return;
        if (!self.found_focus) self.state.focus = self.first;
        if (!self.navigation_consumed) switch (self.navigation orelse return) {
            .next => self.state.focus = self.first,
            .previous => self.state.focus = self.previous,
        };
    }

    fn applyNavigation(self: *Frame, widget_id: Id, was_focused: bool) void {
        const direction = self.navigation orelse return;
        if (direction == .next and self.previous != null and self.previous.? == self.state.focus.?) {
            self.state.focus = widget_id;
            self.navigation_consumed = true;
        }
        if (direction == .previous and was_focused and self.previous != null) {
            self.state.focus = self.previous;
            self.navigation_consumed = true;
        }
    }

    fn drawButton(self: *Frame, rect: Rect, label_text: []const u8, hovered: bool, focused: bool, toggled: bool) void {
        const fill = if (toggled) self.style.toggle_on else if (focused) self.style.focused else if (hovered) self.style.hovered else self.style.idle;
        self.surface.fillRect(rect, fill);
        if (focused) self.surface.strokeRect(rect, self.style.text);
        self.surface.text(label_text, .{ .x = rect.x + 2, .y = rect.y + 2 }, self.style.text);
    }
};

pub fn id(value: []const u8) Id {
    return std.hash.Wyhash.hash(0, value);
}

fn navigation(input: *const Input) ?Navigation {
    if (input.wasPressed(.up) or gamepadPressed(input, .dpad_up)) return .previous;
    if (input.wasPressed(.down) or gamepadPressed(input, .dpad_down)) return .next;
    return null;
}

fn activate(input: *const Input) bool {
    return input.wasPressed(.action) or gamepadPressed(input, .south);
}

fn gamepadPressed(input: *const Input, button: @import("input.zig").GamepadButton) bool {
    for (input.gamepads) |maybe| if (maybe) |gamepad| if (gamepad.wasPressed(button)) return true;
    return false;
}

fn floorToI32(value: f32) i32 {
    return @intFromFloat(@floor(value));
}

fn ceilToI32(value: f32) i32 {
    return @intFromFloat(@ceil(value));
}

test "immediate UI pointer focus and toggle paths" {
    var canvas = try Canvas.init(std.testing.allocator, 32, 16);
    defer canvas.deinit();
    var input = Input{};
    input.setPointerPosition(.{ .x = 3, .y = 3 }, .{ .x = 3, .y = 3 }, .{ .x = 3, .y = 3 });
    input.setPointerButton(.left, true);
    var state = State{};
    var frame = Frame.begin(&state, &input, .{ .hud = &canvas }, .{ .cursor = .{ .x = 1, .y = 1 }, .width = 20 });
    var enabled = false;
    const response = frame.toggle(1, "ENABLE", &enabled);
    frame.end();
    try std.testing.expect(response.hovered and response.focused and response.pressed);
    try std.testing.expect(enabled);
    try std.testing.expectEqual(@as(?Id, 1), state.focus);
    try std.testing.expect(!std.meta.eql(canvas.get(1, 1).?, Color.transparent));
}

test "immediate UI keyboard and gamepad navigation wrap deterministically" {
    var canvas = try Canvas.init(std.testing.allocator, 32, 32);
    defer canvas.deinit();
    var state = State{ .focus = 1 };
    var keyboard = Input{};
    keyboard.set(.down, true);
    var frame = Frame.begin(&state, &keyboard, .{ .hud = &canvas }, .{ .cursor = .{}, .width = 20 });
    _ = frame.button(1, "ONE");
    _ = frame.button(2, "TWO");
    frame.end();
    try std.testing.expectEqual(@as(?Id, 2), state.focus);

    var gamepad = Input{};
    try std.testing.expect(gamepad.addGamepad(7));
    gamepad.setGamepadButton(7, .dpad_down, true);
    frame = Frame.begin(&state, &gamepad, .{ .hud = &canvas }, .{ .cursor = .{}, .width = 20 });
    _ = frame.button(1, "ONE");
    _ = frame.button(2, "TWO");
    frame.end();
    try std.testing.expectEqual(@as(?Id, 1), state.focus);

    gamepad.beginFrame();
    gamepad.setGamepadButton(7, .south, true);
    state.focus = 2;
    frame = Frame.begin(&state, &gamepad, .{ .hud = &canvas }, .{ .cursor = .{}, .width = 20 });
    _ = frame.button(1, "ONE");
    const activated = frame.button(2, "TWO");
    frame.end();
    try std.testing.expect(activated.pressed);
}

test "immediate UI draws in HUD and camera boundaries without retained nodes" {
    var hud = try Canvas.init(std.testing.allocator, 16, 16);
    defer hud.deinit();
    var hud_state = State{};
    var input = Input{};
    var hud_frame = Frame.begin(&hud_state, &input, .{ .hud = &hud }, .{ .cursor = .{ .x = 2, .y = 2 }, .width = 8, .row_height = 4 });
    hud_frame.label("HUD");
    _ = hud_frame.button(1, "OK");
    hud_frame.end();
    try std.testing.expect(!std.meta.eql(hud.get(2, 8).?, Color.transparent));

    var world = try Canvas.init(std.testing.allocator, 16, 16);
    defer world.deinit();
    var camera = @import("camera.zig").Camera2D{ .position = .{ .x = 10, .y = 10 } };
    var world_state = State{};
    var world_frame = Frame.begin(&world_state, &input, .{ .world = .init(&world, &camera) }, .{ .cursor = .{ .x = 10, .y = 10 }, .width = 4 });
    _ = world_frame.button(2, "W");
    world_frame.end();
    try std.testing.expect(!std.meta.eql(world.get(8, 8).?, Color.transparent));
}
