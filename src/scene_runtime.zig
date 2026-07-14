const std = @import("std");
const cache = @import("content_cache.zig");
const ecs = @import("ecs.zig");
const scene = @import("scene.zig");

pub const Binding = struct {
    name: []const u8,
    context: *anyopaque,
    on_load: *const fn (context: *anyopaque, runtime: *const Runtime, entity: ecs.Entity, source: scene.Entity) anyerror!void,
    on_unload: ?*const fn (context: *anyopaque, entity: ecs.Entity, source: scene.Entity) void = null,
};

pub const Diagnostic = struct {
    entity_id: ?[]u8 = null,
    line: usize = 1,
    column: usize = 1,
    message: []const u8 = "scene runtime failed",

    pub fn deinit(self: *Diagnostic, allocator: std.mem.Allocator) void {
        if (self.entity_id) |entity_id| allocator.free(entity_id);
        self.* = .{};
    }
};

const LoadedEntity = struct {
    entity: ecs.Entity,
    source_index: usize,
    binding: ?Binding,
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    world: *ecs.World,
    source: scene.Source,
    entities: []LoadedEntity,
    created_count: usize = 0,
    loaded_count: usize = 0,
    unloaded: bool = false,

    pub fn entity(self: *const Runtime, id: []const u8) ?ecs.Entity {
        for (self.entities) |entry| if (std.mem.eql(u8, self.source.entities[entry.source_index].id, id)) return entry.entity;
        return null;
    }

    pub fn unload(self: *Runtime) !void {
        if (self.unloaded) return;
        var index = self.loaded_count;
        while (index > 0) {
            index -= 1;
            const entry = self.entities[index];
            if (entry.binding) |binding| if (binding.on_unload) |on_unload| on_unload(binding.context, entry.entity, self.source.entities[entry.source_index]);
        }
        index = self.created_count;
        while (index > 0) {
            index -= 1;
            try self.world.destroy(self.entities[index].entity);
        }
        self.loaded_count = 0;
        self.unloaded = true;
    }

    pub fn deinit(self: *Runtime) void {
        self.source.deinit(self.allocator);
        self.allocator.free(self.entities);
        self.* = undefined;
    }
};

pub fn loadCompiled(allocator: std.mem.Allocator, world: *ecs.World, compiled: []const u8, bindings: []const Binding, diagnostic: *Diagnostic) !Runtime {
    var decoded = cache.decode(allocator, compiled) catch |err| {
        try setDiagnostic(allocator, diagnostic, null, 1, 1, "invalid compiled scene");
        return err;
    };
    defer decoded.deinit();
    if (decoded.kind != .scene) {
        try setDiagnostic(allocator, diagnostic, null, 1, 1, "compiled content is not a scene");
        return error.InvalidCompiledScene;
    }
    return loadSource(allocator, world, decoded.payload, bindings, diagnostic);
}

pub fn loadSource(allocator: std.mem.Allocator, world: *ecs.World, source_bytes: []const u8, bindings: []const Binding, diagnostic: *Diagnostic) !Runtime {
    var source_diagnostic = scene.Diagnostic{};
    var source = scene.parse(allocator, source_bytes, &source_diagnostic) catch |err| {
        try setDiagnostic(allocator, diagnostic, null, source_diagnostic.line, source_diagnostic.column, source_diagnostic.message);
        return err;
    };
    var source_transferred = false;
    errdefer if (!source_transferred) source.deinit(allocator);
    try validateBindings(allocator, bindings, diagnostic);
    const entities = try allocator.alloc(LoadedEntity, source.entities.len);
    var runtime = Runtime{
        .allocator = allocator,
        .world = world,
        .source = source,
        .entities = entities,
    };
    source_transferred = true;
    errdefer {
        runtime.unload() catch {};
        runtime.deinit();
    }
    for (source.entities, 0..) |entity, index| {
        const binding = if (entity.binding) |name| findBinding(bindings, name) orelse {
            try setDiagnostic(allocator, diagnostic, entity.id, 1, 1, "scene entity references an unregistered code binding");
            return error.MissingSceneBinding;
        } else null;
        runtime.entities[index] = .{
            .entity = try world.create(),
            .source_index = index,
            .binding = binding,
        };
        runtime.created_count = index + 1;
    }
    for (runtime.entities, 0..) |entry, index| {
        if (entry.binding) |binding| binding.on_load(binding.context, &runtime, entry.entity, runtime.source.entities[entry.source_index]) catch {
            try setDiagnostic(allocator, diagnostic, runtime.source.entities[entry.source_index].id, 1, 1, "scene code binding load callback failed");
            return error.SceneBindingLoadFailed;
        };
        runtime.loaded_count = index + 1;
    }
    return runtime;
}

fn validateBindings(allocator: std.mem.Allocator, bindings: []const Binding, diagnostic: *Diagnostic) !void {
    for (bindings, 0..) |binding, index| {
        if (binding.name.len == 0) {
            try setDiagnostic(allocator, diagnostic, null, 1, 1, "scene code bindings require nonempty names");
            return error.InvalidSceneBinding;
        }
        for (bindings[0..index]) |previous| if (std.mem.eql(u8, previous.name, binding.name)) {
            try setDiagnostic(allocator, diagnostic, null, 1, 1, "scene code binding names must be unique");
            return error.DuplicateSceneBinding;
        };
    }
}

fn findBinding(bindings: []const Binding, name: []const u8) ?Binding {
    for (bindings) |binding| if (std.mem.eql(u8, binding.name, name)) return binding;
    return null;
}

fn setDiagnostic(allocator: std.mem.Allocator, diagnostic: *Diagnostic, entity_id: ?[]const u8, line: usize, column: usize, message: []const u8) !void {
    diagnostic.deinit(allocator);
    diagnostic.* = .{
        .entity_id = if (entity_id) |value| try allocator.dupe(u8, value) else null,
        .line = line,
        .column = column,
        .message = message,
    };
}

test "compiled scenes load and unload bindings deterministically" {
    const source =
        \\.{
        \\    .format = "unpolished-peas-scene",
        \\    .version = 1,
        \\    .metadata = .{ .name = "main", .tags = .{} },
        \\    .entities = .{
        \\        .{ .id = "camera", .name = "Camera", .binding = "record", .components = .{}, .references = .{} },
        \\        .{ .id = "player", .name = "Player", .parent = "camera", .binding = "record", .components = .{}, .references = .{} },
        \\    },
        \\}
    ;
    const Recorder = struct {
        events: [4][]const u8 = undefined,
        count: usize = 0,

        fn load(context: *anyopaque, runtime: *const Runtime, entity: ecs.Entity, source_entity: scene.Entity) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            try runtime.world.validate(entity);
            if (std.mem.eql(u8, source_entity.id, "player")) try std.testing.expect(runtime.entity("camera") != null);
            self.events[self.count] = if (std.mem.eql(u8, source_entity.id, "camera")) "load-camera" else "load-player";
            self.count += 1;
        }

        fn unload(context: *anyopaque, _: ecs.Entity, source_entity: scene.Entity) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.events[self.count] = if (std.mem.eql(u8, source_entity.id, "camera")) "unload-camera" else "unload-player";
            self.count += 1;
        }
    };
    const compiled = try cache.encode(std.testing.allocator, .scene, 1, source);
    defer std.testing.allocator.free(compiled);
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    var recorder = Recorder{};
    var diagnostic = Diagnostic{};
    defer diagnostic.deinit(std.testing.allocator);
    var runtime = try loadCompiled(std.testing.allocator, &world, compiled, &.{.{ .name = "record", .context = &recorder, .on_load = Recorder.load, .on_unload = Recorder.unload }}, &diagnostic);
    try std.testing.expect(runtime.entity("player") != null);
    try runtime.unload();
    runtime.deinit();
    try std.testing.expectEqualSlices([]const u8, &.{ "load-camera", "load-player", "unload-player", "unload-camera" }, recorder.events[0..recorder.count]);
    const entities = try world.entities(std.testing.allocator);
    defer std.testing.allocator.free(entities);
    try std.testing.expectEqual(@as(usize, 0), entities.len);
}

test "scene bindings report contextual failures and roll back entities" {
    const source =
        \\.{
        \\    .format = "unpolished-peas-scene",
        \\    .version = 1,
        \\    .metadata = .{ .name = "main", .tags = .{} },
        \\    .entities = .{ .{ .id = "player", .name = "Player", .binding = "missing", .components = .{}, .references = .{} } },
        \\}
    ;
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    var diagnostic = Diagnostic{};
    defer diagnostic.deinit(std.testing.allocator);
    try std.testing.expectError(error.MissingSceneBinding, loadSource(std.testing.allocator, &world, source, &.{}, &diagnostic));
    try std.testing.expectEqualStrings("player", diagnostic.entity_id.?);
    try std.testing.expectEqualStrings("scene entity references an unregistered code binding", diagnostic.message);
    const entities = try world.entities(std.testing.allocator);
    defer std.testing.allocator.free(entities);
    try std.testing.expectEqual(@as(usize, 0), entities.len);
}

test "scene binding callback failures roll back entities" {
    const source =
        \\.{
        \\    .format = "unpolished-peas-scene",
        \\    .version = 1,
        \\    .metadata = .{ .name = "main", .tags = .{} },
        \\    .entities = .{ .{ .id = "player", .name = "Player", .binding = "fail", .components = .{}, .references = .{} } },
        \\}
    ;
    const FailingBinding = struct {
        fn load(_: *anyopaque, _: *const Runtime, _: ecs.Entity, _: scene.Entity) !void {
            return error.UserBindingFailure;
        }
    };
    var context: u8 = 0;
    var world = ecs.World.init(std.testing.allocator);
    defer world.deinit();
    var diagnostic = Diagnostic{};
    defer diagnostic.deinit(std.testing.allocator);
    try std.testing.expectError(error.SceneBindingLoadFailed, loadSource(std.testing.allocator, &world, source, &.{.{ .name = "fail", .context = &context, .on_load = FailingBinding.load }}, &diagnostic));
    try std.testing.expectEqualStrings("player", diagnostic.entity_id.?);
    try std.testing.expectEqualStrings("scene code binding load callback failed", diagnostic.message);
    const entities = try world.entities(std.testing.allocator);
    defer std.testing.allocator.free(entities);
    try std.testing.expectEqual(@as(usize, 0), entities.len);
}
