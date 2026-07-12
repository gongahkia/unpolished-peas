const std = @import("std");
const input = @import("input.zig");

pub const Binding = union(enum) { key: input.Key, gamepad_button: input.GamepadButton, gamepad_axis: struct { axis: input.GamepadAxis, sign: i8 = 1, threshold: f32 = 0.5 } };
pub const Action = struct { name: []const u8, context: []const u8 = "game", binding: Binding };

pub const Map = struct {
    actions: []const Action,
    pub fn value(self: Map, state: input.Input, context: []const u8, name: []const u8) f32 {
        for (self.actions) |action| {
            if (!std.mem.eql(u8, action.name, name) or !std.mem.eql(u8, action.context, context)) continue;
            return switch (action.binding) {
                .key => |key| if (state.isDown(key)) 1 else 0,
                .gamepad_button => |button| blk: {
                    for (state.gamepads) |maybe| if (maybe) |pad| if (pad.button(button)) break :blk 1;
                    break :blk 0;
                },
                .gamepad_axis => |axis| blk: {
                    for (state.gamepads) |maybe| if (maybe) |pad| {
                        const axis_value = pad.axis(axis.axis) * @as(f32, @floatFromInt(axis.sign));
                        if (axis_value >= axis.threshold) break :blk axis_value;
                    };
                    break :blk 0;
                },
            };
        }
        return 0;
    }
};

pub fn rebind(actions: []Action, context: []const u8, name: []const u8, binding: Binding) bool {
    for (actions) |*action| if (std.mem.eql(u8, action.name, name) and std.mem.eql(u8, action.context, context)) {
        action.binding = binding;
        return true;
    };
    return false;
}

pub fn save(dir: std.fs.Dir, path: []const u8, actions: []const Action) !void {
    var file = try dir.createFile(path, .{ .truncate = true });
    defer file.close();
    var buffer: [256]u8 = undefined;
    for (actions) |action| {
        const line = switch (action.binding) {
            .key => |key| try std.fmt.bufPrint(&buffer, "{s}\t{s}\tkey\t{s}\n", .{ action.context, action.name, @tagName(key) }),
            .gamepad_button => |button| try std.fmt.bufPrint(&buffer, "{s}\t{s}\tbutton\t{s}\n", .{ action.context, action.name, @tagName(button) }),
            .gamepad_axis => |axis| try std.fmt.bufPrint(&buffer, "{s}\t{s}\taxis\t{s}\t{d}\t{d}\n", .{ action.context, action.name, @tagName(axis.axis), axis.sign, axis.threshold }),
        };
        try file.writeAll(line);
    }
}

pub fn load(allocator: std.mem.Allocator, dir: std.fs.Dir, path: []const u8, actions: []Action) !void {
    const bytes = try dir.readFileAlloc(allocator, path, 64 * 1024);
    defer allocator.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const context = fields.next() orelse return error.InvalidBindingFile;
        const name = fields.next() orelse return error.InvalidBindingFile;
        const kind = fields.next() orelse return error.InvalidBindingFile;
        const value = fields.next() orelse return error.InvalidBindingFile;
        const binding: Binding = if (std.mem.eql(u8, kind, "key")) .{ .key = std.meta.stringToEnum(input.Key, value) orelse return error.InvalidBindingFile } else if (std.mem.eql(u8, kind, "button")) .{ .gamepad_button = std.meta.stringToEnum(input.GamepadButton, value) orelse return error.InvalidBindingFile } else if (std.mem.eql(u8, kind, "axis")) .{ .gamepad_axis = .{ .axis = std.meta.stringToEnum(input.GamepadAxis, value) orelse return error.InvalidBindingFile, .sign = try std.fmt.parseInt(i8, fields.next() orelse return error.InvalidBindingFile, 10), .threshold = try std.fmt.parseFloat(f32, fields.next() orelse return error.InvalidBindingFile) } } else return error.InvalidBindingFile;
        if (!rebind(actions, context, name, binding)) return error.UnknownAction;
    }
}

test "named actions map keyboard and gamepad deterministically" {
    var state = input.Input{};
    state.set(.action, true);
    try std.testing.expect(state.addGamepad(1));
    state.setGamepadAxis(1, .left_x, 0.75, 0);
    var actions = [_]Action{ .{ .name = "fire", .binding = .{ .key = .action } }, .{ .name = "move", .binding = .{ .gamepad_axis = .{ .axis = .left_x } } } };
    const map = Map{ .actions = &actions };
    try std.testing.expectEqual(@as(f32, 1), map.value(state, "game", "fire"));
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), map.value(state, "game", "move"), 0.001);
    try std.testing.expect(rebind(&actions, "game", "fire", .{ .gamepad_button = .south }));
}

test "saved rebind restores deterministically" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var actions = [_]Action{.{ .name = "fire", .binding = .{ .key = .action } }};
    try std.testing.expect(rebind(&actions, "game", "fire", .{ .gamepad_button = .south }));
    try save(tmp.dir, "bindings.up", &actions);
    actions[0].binding = .{ .key = .cancel };
    try load(std.testing.allocator, tmp.dir, "bindings.up", &actions);
    try std.testing.expect(switch (actions[0].binding) {
        .gamepad_button => |button| button == .south,
        else => false,
    });
}
