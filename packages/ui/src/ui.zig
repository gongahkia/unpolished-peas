const std = @import("std");

pub fn ui(comptime up: type) type {
    return struct {
        pub const Id = u64;

        pub const State = struct {
            focus: ?Id = null,
        };

        pub const Layout = struct {
            cursor: up.Vec2,
            width: f32,
            row_height: f32 = 12,
            gap: f32 = 2,

            pub fn next(self: *Layout) up.Rect {
                const rect = up.Rect.init(self.cursor.x, self.cursor.y, self.width, self.row_height);
                self.cursor.y += self.row_height + self.gap;
                return rect;
            }
        };

        pub const Style = struct {
            idle: up.Color = up.Color.rgb(42, 50, 66),
            hovered: up.Color = up.Color.rgb(58, 72, 94),
            focused: up.Color = up.Color.rgb(91, 123, 171),
            text: up.Color = up.Color.white,
            toggle_on: up.Color = up.Color.rgb(54, 126, 91),
        };

        pub const Response = struct {
            id: Id,
            rect: up.Rect,
            hovered: bool,
            focused: bool,
            pressed: bool,
        };

        pub const Surface = union(enum) {
            hud: *up.Canvas,
            world: up.CameraCanvas,

            fn pointer(self: Surface, input: *const up.Input) ?up.Vec2 {
                const point = input.pointer.canvas orelse return null;
                return switch (self) {
                    .hud => point,
                    .world => |canvas| canvas.camera.canvasToWorld(point, canvas.canvas_size),
                };
            }

            fn fillRect(self: Surface, rect: up.Rect, color: up.Color) void {
                switch (self) {
                    .hud => |canvas| canvas.fillRect(floorToI32(rect.x), floorToI32(rect.y), ceilToI32(rect.w), ceilToI32(rect.h), color),
                    .world => |canvas| canvas.fillRect(rect, color),
                }
            }

            fn strokeRect(self: Surface, rect: up.Rect, color: up.Color) void {
                switch (self) {
                    .hud => |canvas| canvas.strokeRect(floorToI32(rect.x), floorToI32(rect.y), ceilToI32(rect.w), ceilToI32(rect.h), color),
                    .world => |canvas| canvas.strokeRect(rect, color),
                }
            }

            fn text(self: Surface, value: []const u8, position: up.Vec2, color: up.Color) void {
                switch (self) {
                    .hud => |canvas| canvas.drawText(value, floorToI32(position.x), floorToI32(position.y), color),
                    .world => |canvas| canvas.drawText(value, position, color),
                }
            }
        };

        const Navigation = enum { previous, next };

        pub const Frame = struct {
            state: *State,
            input: *const up.Input,
            surface: Surface,
            layout: Layout,
            style: Style = .{},
            navigation: ?Navigation,
            navigation_consumed: bool = false,
            first: ?Id = null,
            previous: ?Id = null,
            found_focus: bool = false,

            pub fn begin(state: *State, input: *const up.Input, surface: Surface, layout: Layout) Frame {
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

            pub fn buttonAt(self: *Frame, widget_id: Id, rect: up.Rect, label_text: []const u8) Response {
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

            fn drawButton(self: *Frame, rect: up.Rect, label_text: []const u8, hovered: bool, focused: bool, toggled: bool) void {
                const fill = if (toggled) self.style.toggle_on else if (focused) self.style.focused else if (hovered) self.style.hovered else self.style.idle;
                self.surface.fillRect(rect, fill);
                if (focused) self.surface.strokeRect(rect, self.style.text);
                self.surface.text(label_text, .{ .x = rect.x + 2, .y = rect.y + 2 }, self.style.text);
            }
        };

        pub fn id(value: []const u8) Id {
            return std.hash.Wyhash.hash(0, value);
        }

        fn navigation(input: *const up.Input) ?Navigation {
            if (input.wasPressed(.up) or gamepadPressed(input, .dpad_up)) return .previous;
            if (input.wasPressed(.down) or gamepadPressed(input, .dpad_down)) return .next;
            return null;
        }

        fn activate(input: *const up.Input) bool {
            return input.wasPressed(.action) or gamepadPressed(input, .south);
        }

        fn gamepadPressed(input: *const up.Input, button: up.GamepadButton) bool {
            for (input.gamepads) |maybe| if (maybe) |gamepad| if (gamepad.wasPressed(button)) return true;
            return false;
        }

        fn floorToI32(value: f32) i32 {
            return @intFromFloat(@floor(value));
        }

        fn ceilToI32(value: f32) i32 {
            return @intFromFloat(@ceil(value));
        }
    };
}
