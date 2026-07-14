const std = @import("std");
const atlas = @import("atlas.zig");
const Canvas = @import("canvas.zig").Canvas;
const Color = @import("color.zig").Color;
const ecs = @import("ecs.zig");
const scene = @import("scene.zig");
const scene_runtime = @import("scene_runtime.zig");

pub const BlendPolicy = enum { immediate, hold_previous };

pub const Transition = struct {
    trigger: []const u8,
    target: []const u8,
    blend_ticks: u32 = 0,
    blend_policy: BlendPolicy = .immediate,
};

pub const State = struct {
    name: []const u8,
    animation: atlas.AnimationHandle,
    loop: bool = true,
    transitions: []const Transition = &.{},
};

pub const EventKind = enum { entered, transitioned, frame };

pub const Event = struct {
    kind: EventKind,
    state: []const u8,
    trigger: ?[]const u8 = null,
    frame: ?atlas.AtlasFrameHandle = null,
};

pub const Diagnostic = struct {
    state: ?[]const u8 = null,
    transition: ?[]const u8 = null,
    message: []const u8 = "invalid animation state machine",
};

const Pending = struct {
    target: usize,
    remaining_ticks: u32,
};

pub const Machine = struct {
    allocator: std.mem.Allocator,
    atlas: *const atlas.Atlas,
    states: []const State,
    current: usize,
    frame_index: usize = 0,
    frame_elapsed_ticks: u32 = 0,
    pending: ?Pending = null,
    events: std.ArrayListUnmanaged(Event) = .{},

    pub fn init(allocator: std.mem.Allocator, texture_atlas: *const atlas.Atlas, states: []const State, initial: []const u8, diagnostic: *Diagnostic) !Machine {
        try validate(texture_atlas, states, initial, diagnostic);
        const initial_index = findState(states, initial).?;
        var result = Machine{
            .allocator = allocator,
            .atlas = texture_atlas,
            .states = states,
            .current = initial_index,
        };
        errdefer result.deinit();
        try result.events.append(allocator, .{ .kind = .entered, .state = states[initial_index].name, .frame = result.frame() });
        return result;
    }

    pub fn deinit(self: *Machine) void {
        self.events.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn state(self: Machine) State {
        return self.states[self.current];
    }

    pub fn frame(self: Machine) atlas.AtlasFrameHandle {
        const animation = self.atlas.animation(self.state().animation);
        return animation.frames[self.frame_index].frame;
    }

    pub fn transition(self: *Machine, trigger: []const u8, diagnostic: *Diagnostic) !void {
        const source = self.state();
        const selected = findTransition(source.transitions, trigger) orelse {
            diagnostic.* = .{ .state = source.name, .transition = trigger, .message = "animation transition is not available from the current state" };
            return error.MissingAnimationTransition;
        };
        const target = findState(self.states, selected.target) orelse unreachable;
        try self.events.append(self.allocator, .{ .kind = .transitioned, .state = self.states[target].name, .trigger = trigger });
        if (selected.blend_policy == .hold_previous and selected.blend_ticks != 0) {
            self.pending = .{ .target = target, .remaining_ticks = selected.blend_ticks };
            return;
        }
        try self.enter(target);
    }

    pub fn update(self: *Machine, ticks: u32) !void {
        var remaining = ticks;
        while (remaining != 0) {
            if (self.pending) |*pending| {
                if (remaining < pending.remaining_ticks) {
                    pending.remaining_ticks -= remaining;
                    return;
                }
                remaining -= pending.remaining_ticks;
                const target = pending.target;
                self.pending = null;
                try self.enter(target);
                continue;
            }
            const animation = self.atlas.animation(self.state().animation);
            const duration = frameTicks(animation.frames[self.frame_index].duration);
            const until_next = duration - self.frame_elapsed_ticks;
            if (remaining < until_next) {
                self.frame_elapsed_ticks += remaining;
                return;
            }
            remaining -= until_next;
            self.frame_elapsed_ticks = 0;
            if (self.frame_index + 1 == animation.frames.len) {
                if (!self.state().loop) return;
                self.frame_index = 0;
            } else self.frame_index += 1;
            try self.events.append(self.allocator, .{ .kind = .frame, .state = self.state().name, .frame = self.frame() });
        }
    }

    pub fn drainEvents(self: *Machine, allocator: std.mem.Allocator) ![]Event {
        const result = try allocator.dupe(Event, self.events.items);
        self.events.clearRetainingCapacity();
        return result;
    }

    fn enter(self: *Machine, target: usize) !void {
        self.current = target;
        self.frame_index = 0;
        self.frame_elapsed_ticks = 0;
        try self.events.append(self.allocator, .{ .kind = .entered, .state = self.state().name, .frame = self.frame() });
    }
};

pub const SceneBinding = struct {
    machine: *Machine,
    diagnostic: *Diagnostic,
    trigger: ?[]const u8 = null,
    entity: ?ecs.Entity = null,

    pub fn binding(self: *SceneBinding, name: []const u8) scene_runtime.Binding {
        return .{
            .name = name,
            .context = self,
            .on_load = onLoad,
            .on_unload = onUnload,
        };
    }

    fn onLoad(context: *anyopaque, _: *const scene_runtime.Runtime, entity: ecs.Entity, _: scene.Entity) anyerror!void {
        const self: *SceneBinding = @ptrCast(@alignCast(context));
        self.entity = entity;
        if (self.trigger) |trigger| try self.machine.transition(trigger, self.diagnostic);
    }

    fn onUnload(context: *anyopaque, _: ecs.Entity, _: scene.Entity) void {
        const self: *SceneBinding = @ptrCast(@alignCast(context));
        self.entity = null;
    }
};

fn validate(texture_atlas: *const atlas.Atlas, states: []const State, initial: []const u8, diagnostic: *Diagnostic) !void {
    if (states.len == 0) {
        diagnostic.* = .{ .message = "animation state machines require at least one state" };
        return error.InvalidAnimationDefinition;
    }
    for (states, 0..) |state, state_index| {
        if (state.name.len == 0 or state.animation.index >= texture_atlas.animations.len or texture_atlas.animation(state.animation).frames.len == 0) {
            diagnostic.* = .{ .state = state.name, .message = "animation states require names and nonempty atlas animations" };
            return error.InvalidAnimationDefinition;
        }
        for (states[0..state_index]) |previous| if (std.mem.eql(u8, previous.name, state.name)) {
            diagnostic.* = .{ .state = state.name, .message = "animation state names must be unique" };
            return error.InvalidAnimationDefinition;
        };
        for (state.transitions, 0..) |transition, transition_index| {
            if (transition.trigger.len == 0 or findState(states, transition.target) == null) {
                diagnostic.* = .{ .state = state.name, .transition = transition.trigger, .message = "animation transitions require triggers and known target states" };
                return error.InvalidAnimationDefinition;
            }
            for (state.transitions[0..transition_index]) |previous| if (std.mem.eql(u8, previous.trigger, transition.trigger)) {
                diagnostic.* = .{ .state = state.name, .transition = transition.trigger, .message = "animation transition triggers must be unique within a state" };
                return error.InvalidAnimationDefinition;
            };
        }
    }
    if (findState(states, initial) == null) {
        diagnostic.* = .{ .state = initial, .message = "initial animation state is unknown" };
        return error.InvalidAnimationDefinition;
    }
}

fn findState(states: []const State, name: []const u8) ?usize {
    for (states, 0..) |state, index| if (std.mem.eql(u8, state.name, name)) return index;
    return null;
}

fn findTransition(transitions: []const Transition, trigger: []const u8) ?Transition {
    for (transitions) |transition| if (std.mem.eql(u8, transition.trigger, trigger)) return transition;
    return null;
}

fn frameTicks(duration: f32) u32 {
    return @max(1, @as(u32, @intFromFloat(@round(duration * 60))));
}

fn testAtlas() !atlas.Atlas {
    const pixels = try std.testing.allocator.dupe(Color, &.{ Color.rgb(255, 0, 0), Color.rgb(0, 255, 0) });
    return .{
        .allocator = std.testing.allocator,
        .image = .{ .allocator = std.testing.allocator, .width = 2, .height = 1, .pixels = pixels },
        .image_path = try std.testing.allocator.dupe(u8, "memory.png"),
        .frames = try std.testing.allocator.dupe(atlas.AtlasFrame, &.{
            .{ .name = try std.testing.allocator.dupe(u8, "idle"), .x = 0, .y = 0, .w = 1, .h = 1, .source_w = 1, .source_h = 1, .offset_x = 0, .offset_y = 0 },
            .{ .name = try std.testing.allocator.dupe(u8, "walk"), .x = 1, .y = 0, .w = 1, .h = 1, .source_w = 1, .source_h = 1, .offset_x = 0, .offset_y = 0 },
        }),
        .animations = try std.testing.allocator.dupe(atlas.Animation, &.{
            .{
                .name = try std.testing.allocator.dupe(u8, "idle"),
                .frames = try std.testing.allocator.dupe(atlas.AnimationFrame, &.{.{ .frame = .{ .index = 0 }, .duration = 0.1 }}),
            },
            .{
                .name = try std.testing.allocator.dupe(u8, "walk"),
                .frames = try std.testing.allocator.dupe(atlas.AnimationFrame, &.{.{ .frame = .{ .index = 1 }, .duration = 0.1 }}),
            },
        }),
    };
}

test "animation state transitions are replayable with hold blending" {
    var texture_atlas = try testAtlas();
    defer texture_atlas.deinit();
    const states = [_]State{
        .{ .name = "idle", .animation = .{ .index = 0 }, .transitions = &.{.{ .trigger = "walk", .target = "walk", .blend_ticks = 2, .blend_policy = .hold_previous }} },
        .{ .name = "walk", .animation = .{ .index = 1 } },
    };
    var diagnostic = Diagnostic{};
    var machine = try Machine.init(std.testing.allocator, &texture_atlas, &states, "idle", &diagnostic);
    defer machine.deinit();
    try machine.transition("walk", &diagnostic);
    try machine.update(1);
    try std.testing.expectEqual(@as(usize, 0), machine.frame().index);
    try machine.update(1);
    try std.testing.expectEqual(@as(usize, 1), machine.frame().index);
    const events = try machine.drainEvents(std.testing.allocator);
    defer std.testing.allocator.free(events);
    try std.testing.expectEqualSlices(EventKind, &.{ .entered, .transitioned, .entered }, &.{ events[0].kind, events[1].kind, events[2].kind });
    try std.testing.expectEqualStrings("idle", events[0].state);
    try std.testing.expectEqualStrings("walk", events[2].state);
}

test "invalid animation transitions diagnose source definitions" {
    var texture_atlas = try testAtlas();
    defer texture_atlas.deinit();
    const states = [_]State{
        .{ .name = "idle", .animation = .{ .index = 0 }, .transitions = &.{.{ .trigger = "walk", .target = "missing" }} },
    };
    var diagnostic = Diagnostic{};
    try std.testing.expectError(error.InvalidAnimationDefinition, Machine.init(std.testing.allocator, &texture_atlas, &states, "idle", &diagnostic));
    try std.testing.expectEqualStrings("idle", diagnostic.state.?);
    try std.testing.expectEqualStrings("walk", diagnostic.transition.?);
    try std.testing.expectEqualStrings("animation transitions require triggers and known target states", diagnostic.message);
}

test "animation state sprite output preserves the configured blend policy" {
    var texture_atlas = try testAtlas();
    defer texture_atlas.deinit();
    const states = [_]State{
        .{ .name = "idle", .animation = .{ .index = 0 }, .transitions = &.{.{ .trigger = "walk", .target = "walk", .blend_ticks = 2, .blend_policy = .hold_previous }} },
        .{ .name = "walk", .animation = .{ .index = 1 } },
    };
    var diagnostic = Diagnostic{};
    var machine = try Machine.init(std.testing.allocator, &texture_atlas, &states, "idle", &diagnostic);
    defer machine.deinit();
    var canvas = try Canvas.init(std.testing.allocator, 1, 1);
    defer canvas.deinit();
    try machine.transition("walk", &diagnostic);
    try machine.update(1);
    canvas.clear(Color.black);
    canvas.drawAtlasFrame(texture_atlas, machine.frame(), 0, 0, .{});
    try std.testing.expectEqual(Color.rgb(255, 0, 0), canvas.get(0, 0).?);
    try machine.update(1);
    canvas.clear(Color.black);
    canvas.drawAtlasFrame(texture_atlas, machine.frame(), 0, 0, .{});
    try std.testing.expectEqual(Color.rgb(0, 255, 0), canvas.get(0, 0).?);
}

test "animation state machines bind through native scene lifecycle callbacks" {
    const source =
        \\.{
        \\    .format = "unpolished-peas-scene",
        \\    .version = 1,
        \\    .metadata = .{ .name = "main", .tags = .{} },
        \\    .entities = .{ .{ .id = "player", .name = "Player", .binding = "animation", .components = .{}, .references = .{} } },
        \\}
    ;
    var texture_atlas = try testAtlas();
    defer texture_atlas.deinit();
    const states = [_]State{
        .{ .name = "idle", .animation = .{ .index = 0 }, .transitions = &.{.{ .trigger = "walk", .target = "walk" }} },
        .{ .name = "walk", .animation = .{ .index = 1 } },
    };
    var diagnostic = Diagnostic{};
    var machine = try Machine.init(std.testing.allocator, &texture_atlas, &states, "idle", &diagnostic);
    defer machine.deinit();
    var binding_context = SceneBinding{ .machine = &machine, .diagnostic = &diagnostic, .trigger = "walk" };
    var runtime_diagnostic = scene_runtime.Diagnostic{};
    defer runtime_diagnostic.deinit(std.testing.allocator);
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    var runtime = try scene_runtime.loadSource(std.testing.allocator, &world, source, &.{binding_context.binding("animation")}, &runtime_diagnostic);
    try std.testing.expect(binding_context.entity != null);
    try std.testing.expectEqualStrings("walk", machine.state().name);
    try runtime.unload();
    runtime.deinit();
    try std.testing.expect(binding_context.entity == null);
}
