const std = @import("std");
const input = @import("input.zig");

pub const Binding = union(enum) {
    key: input.Key,
    pointer_button: input.PointerButton,
    gamepad_button: input.GamepadButton,
    gamepad_axis: struct {
        axis: input.GamepadAxis,
        sign: i8 = 1,
        threshold: f32 = 0.5,
    },
};

pub const Action = struct {
    name: []const u8,
    context: []const u8 = "game",
    binding: Binding,
};

pub const Map = struct {
    actions: []const Action,
    owned_actions: ?[]Action = null,
    allocator: ?std.mem.Allocator = null,
    values: ?[]f32 = null,
    previous_values: ?[]f32 = null,
    app_data_path: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, definitions: []const Action) !Map {
        try validateActions(definitions);
        const owned_actions = try allocator.dupe(Action, definitions);
        errdefer allocator.free(owned_actions);
        const values = try allocator.alloc(f32, definitions.len);
        errdefer allocator.free(values);
        const previous_values = try allocator.alloc(f32, definitions.len);
        @memset(values, 0);
        @memset(previous_values, 0);
        return .{
            .actions = owned_actions,
            .owned_actions = owned_actions,
            .allocator = allocator,
            .values = values,
            .previous_values = previous_values,
        };
    }

    pub fn deinit(self: *Map) void {
        const allocator = self.allocator orelse return;
        if (self.previous_values) |values| allocator.free(values);
        if (self.values) |values| allocator.free(values);
        if (self.owned_actions) |actions| allocator.free(actions);
        self.* = undefined;
    }

    pub fn attachAppData(self: *Map, path: []const u8) void {
        self.app_data_path = path;
    }

    pub fn validate(definitions: []const Action) !void {
        try validateActions(definitions);
    }

    pub fn update(self: *Map, state: input.Input) void {
        const values = self.values orelse return;
        const previous_values = self.previous_values orelse return;
        std.mem.copyForwards(f32, previous_values, values);
        for (self.actions, 0..) |action, index| values[index] = bindingValue(state, action.binding);
    }

    pub fn value(self: Map, state: input.Input, context: []const u8, name: []const u8) f32 {
        var result: f32 = 0;
        for (self.actions) |action| {
            if (!matches(action, context, name)) continue;
            result = @max(result, bindingValue(state, action.binding));
        }
        return result;
    }

    pub fn isDown(self: Map, context: []const u8, name: []const u8) bool {
        const values = self.values orelse return false;
        return actionValue(self.actions, values, context, name) > 0;
    }

    pub fn wasPressed(self: Map, context: []const u8, name: []const u8) bool {
        const values = self.values orelse return false;
        const previous_values = self.previous_values orelse return false;
        return actionValue(self.actions, values, context, name) > 0 and actionValue(self.actions, previous_values, context, name) == 0;
    }

    pub fn wasReleased(self: Map, context: []const u8, name: []const u8) bool {
        const values = self.values orelse return false;
        const previous_values = self.previous_values orelse return false;
        return actionValue(self.actions, values, context, name) == 0 and actionValue(self.actions, previous_values, context, name) > 0;
    }

    pub fn rebind(self: *Map, context: []const u8, name: []const u8, binding: Binding) !void {
        try self.rebindBinding(context, name, 0, binding);
    }

    pub fn rebindBinding(self: *Map, context: []const u8, name: []const u8, binding_index: usize, binding: Binding) !void {
        const actions = try self.mutableActions();
        const index = findAction(actions, context, name, binding_index) orelse return error.UnknownAction;
        try self.rebindAt(index, binding);
    }

    pub fn rebindAt(self: *Map, index: usize, binding: Binding) !void {
        const actions = try self.mutableActions();
        if (index >= actions.len) return error.UnknownAction;
        try validateBinding(binding);
        if (duplicateBinding(actions, index, binding)) return error.DuplicateBinding;
        const previous = actions[index].binding;
        actions[index].binding = binding;
        self.persist() catch |err| {
            actions[index].binding = previous;
            return err;
        };
    }

    pub fn save(self: Map, dir: std.fs.Dir, path: []const u8) !void {
        try saveBindings(dir, path, self.actions);
    }

    pub fn load(self: *Map, dir: std.fs.Dir, path: []const u8) !void {
        const actions = try self.mutableActions();
        const allocator = self.allocator orelse return error.ImmutableActionMap;
        const original = try allocator.alloc(Binding, actions.len);
        defer allocator.free(original);
        for (actions, 0..) |action, index| original[index] = action.binding;
        errdefer {
            for (actions, 0..) |*action, index| action.binding = original[index];
        }

        const bytes = try dir.readFileAlloc(allocator, path, 64 * 1024);
        defer allocator.free(bytes);
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var fields = std.mem.splitScalar(u8, line, '\t');
            const context = fields.next() orelse return error.InvalidBindingFile;
            const name = fields.next() orelse return error.InvalidBindingFile;
            const third = fields.next() orelse return error.InvalidBindingFile;
            var binding_index: usize = 0;
            const kind = if (isBindingKind(third)) third else blk: {
                binding_index = std.fmt.parseInt(usize, third, 10) catch return error.InvalidBindingFile;
                break :blk fields.next() orelse return error.InvalidBindingFile;
            };
            const binding = try parseBinding(kind, &fields);
            if (fields.next() != null) return error.InvalidBindingFile;
            const index = findAction(actions, context, name, binding_index) orelse return error.UnknownAction;
            actions[index].binding = binding;
        }
        try validateActions(actions);
    }

    pub fn loadAppData(self: *Map) !void {
        const root = self.app_data_path orelse return;
        var dir = try std.fs.openDirAbsolute(root, .{});
        defer dir.close();
        try self.load(dir, "bindings.up");
    }

    fn mutableActions(self: *Map) ![]Action {
        return self.owned_actions orelse error.ImmutableActionMap;
    }

    fn persist(self: *Map) !void {
        const root = self.app_data_path orelse return;
        var dir = try std.fs.openDirAbsolute(root, .{});
        defer dir.close();
        try self.save(dir, "bindings.up");
    }
};

fn validateActions(actions: []const Action) !void {
    for (actions, 0..) |action, index| {
        if (action.name.len == 0 or action.context.len == 0) return error.InvalidAction;
        try validateBinding(action.binding);
        for (actions[index + 1 ..]) |other| {
            if (matches(other, action.context, action.name) and bindingEql(other.binding, action.binding)) return error.DuplicateBinding;
        }
    }
}

pub fn rebind(actions: []Action, context: []const u8, name: []const u8, binding: Binding) bool {
    validateBinding(binding) catch return false;
    const index = findAction(actions, context, name, 0) orelse return false;
    if (duplicateBinding(actions, index, binding)) return false;
    actions[index].binding = binding;
    return true;
}

pub fn save(dir: std.fs.Dir, path: []const u8, actions: []const Action) !void {
    try saveBindings(dir, path, actions);
}

pub fn load(allocator: std.mem.Allocator, dir: std.fs.Dir, path: []const u8, actions: []Action) !void {
    var map = Map{ .actions = actions, .owned_actions = actions, .allocator = allocator };
    try map.load(dir, path);
}

fn bindingValue(state: input.Input, binding: Binding) f32 {
    return switch (binding) {
        .key => |key| if (state.isDown(key)) 1 else 0,
        .pointer_button => |button| if (state.pointerIsDown(button)) 1 else 0,
        .gamepad_button => |button| blk: {
            for (state.gamepads) |maybe| if (maybe) |pad| if (pad.button(button)) break :blk 1;
            break :blk 0;
        },
        .gamepad_axis => |axis| blk: {
            for (state.gamepads) |maybe| if (maybe) |pad| {
                const value = pad.axis(axis.axis) * @as(f32, @floatFromInt(axis.sign));
                if (value >= axis.threshold) break :blk value;
            };
            break :blk 0;
        },
    };
}

fn actionValue(actions: []const Action, values: []const f32, context: []const u8, name: []const u8) f32 {
    var result: f32 = 0;
    for (actions, values) |action, value| {
        if (matches(action, context, name)) result = @max(result, value);
    }
    return result;
}

fn matches(action: Action, context: []const u8, name: []const u8) bool {
    return std.mem.eql(u8, action.name, name) and std.mem.eql(u8, action.context, context);
}

fn findAction(actions: []const Action, context: []const u8, name: []const u8, binding_index: usize) ?usize {
    var found: usize = 0;
    for (actions, 0..) |action, index| {
        if (!matches(action, context, name)) continue;
        if (found == binding_index) return index;
        found += 1;
    }
    return null;
}

fn bindingIndex(actions: []const Action, index: usize) usize {
    var result: usize = 0;
    for (actions[0..index]) |action| {
        if (matches(action, actions[index].context, actions[index].name)) result += 1;
    }
    return result;
}

fn duplicateBinding(actions: []const Action, skip: usize, binding: Binding) bool {
    const action = actions[skip];
    for (actions, 0..) |other, index| {
        if (index != skip and matches(other, action.context, action.name) and bindingEql(other.binding, binding)) return true;
    }
    return false;
}

fn validateBinding(binding: Binding) !void {
    switch (binding) {
        .gamepad_axis => |axis| {
            if ((axis.sign != -1 and axis.sign != 1) or !(axis.threshold > 0 and axis.threshold <= 1)) return error.InvalidBinding;
        },
        else => {},
    }
}

fn bindingEql(a: Binding, b: Binding) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .key => |key| key == b.key,
        .pointer_button => |button| button == b.pointer_button,
        .gamepad_button => |button| button == b.gamepad_button,
        .gamepad_axis => |axis| axis.axis == b.gamepad_axis.axis and axis.sign == b.gamepad_axis.sign and axis.threshold == b.gamepad_axis.threshold,
    };
}

fn isBindingKind(value: []const u8) bool {
    return std.mem.eql(u8, value, "key") or std.mem.eql(u8, value, "pointer") or std.mem.eql(u8, value, "button") or std.mem.eql(u8, value, "axis");
}

fn parseBinding(kind: []const u8, fields: *std.mem.SplitIterator(u8, .scalar)) !Binding {
    const value = fields.next() orelse return error.InvalidBindingFile;
    if (std.mem.eql(u8, kind, "key")) return .{ .key = std.meta.stringToEnum(input.Key, value) orelse return error.InvalidBindingFile };
    if (std.mem.eql(u8, kind, "pointer")) return .{ .pointer_button = std.meta.stringToEnum(input.PointerButton, value) orelse return error.InvalidBindingFile };
    if (std.mem.eql(u8, kind, "button")) return .{ .gamepad_button = std.meta.stringToEnum(input.GamepadButton, value) orelse return error.InvalidBindingFile };
    if (std.mem.eql(u8, kind, "axis")) return .{ .gamepad_axis = .{
        .axis = std.meta.stringToEnum(input.GamepadAxis, value) orelse return error.InvalidBindingFile,
        .sign = std.fmt.parseInt(i8, fields.next() orelse return error.InvalidBindingFile, 10) catch return error.InvalidBindingFile,
        .threshold = std.fmt.parseFloat(f32, fields.next() orelse return error.InvalidBindingFile) catch return error.InvalidBindingFile,
    } };
    return error.InvalidBindingFile;
}

fn saveBindings(dir: std.fs.Dir, path: []const u8, actions: []const Action) !void {
    try validateActions(actions);
    var file = try dir.createFile(path, .{ .truncate = true });
    defer file.close();
    var buffer: [256]u8 = undefined;
    for (actions, 0..) |action, index| {
        const ordinal = bindingIndex(actions, index);
        const line = switch (action.binding) {
            .key => |key| try std.fmt.bufPrint(&buffer, "{s}\t{s}\t{d}\tkey\t{s}\n", .{ action.context, action.name, ordinal, @tagName(key) }),
            .pointer_button => |button| try std.fmt.bufPrint(&buffer, "{s}\t{s}\t{d}\tpointer\t{s}\n", .{ action.context, action.name, ordinal, @tagName(button) }),
            .gamepad_button => |button| try std.fmt.bufPrint(&buffer, "{s}\t{s}\t{d}\tbutton\t{s}\n", .{ action.context, action.name, ordinal, @tagName(button) }),
            .gamepad_axis => |axis| try std.fmt.bufPrint(&buffer, "{s}\t{s}\t{d}\taxis\t{s}\t{d}\t{d}\n", .{ action.context, action.name, ordinal, @tagName(axis.axis), axis.sign, axis.threshold }),
        };
        try file.writeAll(line);
    }
}

test "action maps merge keyboard mouse and gamepad edges deterministically" {
    var state = input.Input{};
    var actions = try Map.init(std.testing.allocator, &.{
        .{ .name = "fire", .binding = .{ .key = .action } },
        .{ .name = "fire", .binding = .{ .pointer_button = .left } },
        .{ .name = "fire", .binding = .{ .gamepad_button = .south } },
        .{ .name = "move", .binding = .{ .gamepad_axis = .{ .axis = .left_x } } },
    });
    defer actions.deinit();

    state.set(.action, true);
    state.setPointerButton(.left, true);
    try std.testing.expect(state.addGamepad(1));
    state.setGamepadButton(1, .south, true);
    state.setGamepadAxis(1, .left_x, 0.75, 0);
    actions.update(state);
    try std.testing.expectEqual(@as(f32, 1), actions.value(state, "game", "fire"));
    try std.testing.expect(actions.isDown("game", "fire"));
    try std.testing.expect(actions.wasPressed("game", "fire"));
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), actions.value(state, "game", "move"), 0.001);

    state.beginFrame();
    actions.update(state);
    try std.testing.expect(!actions.wasPressed("game", "fire"));
    state.set(.action, false);
    state.setPointerButton(.left, false);
    state.setGamepadButton(1, .south, false);
    actions.update(state);
    try std.testing.expect(actions.wasReleased("game", "fire"));
}

test "rebind persists gamepad bindings across map restarts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const app_data_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(app_data_path);
    const definitions = [_]Action{
        .{ .name = "fire", .binding = .{ .key = .action } },
        .{ .name = "fire", .binding = .{ .pointer_button = .left } },
    };
    var actions = try Map.init(std.testing.allocator, &definitions);
    defer actions.deinit();
    actions.attachAppData(app_data_path);

    try actions.rebind("game", "fire", .{ .gamepad_button = .south });
    try actions.rebindBinding("game", "fire", 1, .{ .gamepad_axis = .{ .axis = .left_x, .sign = -1, .threshold = 0.7 } });
    try std.testing.expectError(error.DuplicateBinding, actions.rebindBinding("game", "fire", 1, .{ .gamepad_button = .south }));

    var restored = try Map.init(std.testing.allocator, &definitions);
    defer restored.deinit();
    restored.attachAppData(app_data_path);
    try restored.loadAppData();
    try std.testing.expect(bindingEql(restored.actions[0].binding, .{ .gamepad_button = .south }));
    try std.testing.expect(bindingEql(restored.actions[1].binding, .{ .gamepad_axis = .{ .axis = .left_x, .sign = -1, .threshold = 0.7 } }));

    var state = input.Input{};
    try std.testing.expect(state.addGamepad(1));
    state.setGamepadButton(1, .south, true);
    state.setGamepadAxis(1, .left_x, -0.8, 0);
    restored.update(state);
    try std.testing.expect(restored.isDown("game", "fire"));
    try std.testing.expect(restored.wasPressed("game", "fire"));
}

test "device removal and reconnect produce deterministic action edges" {
    var state = input.Input{};
    var actions = try Map.init(std.testing.allocator, &.{.{ .name = "fire", .binding = .{ .gamepad_button = .south } }});
    defer actions.deinit();

    try std.testing.expect(state.addGamepad(7));
    state.setGamepadButton(7, .south, true);
    actions.update(state);
    try std.testing.expect(actions.wasPressed("game", "fire"));
    state.beginFrame();
    _ = state.removeGamepad(7);
    actions.update(state);
    try std.testing.expect(actions.wasReleased("game", "fire"));
    state.beginFrame();
    try std.testing.expect(state.addGamepad(7));
    state.setGamepadButton(7, .south, true);
    actions.update(state);
    try std.testing.expect(actions.wasPressed("game", "fire"));
}
