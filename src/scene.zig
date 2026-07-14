const std = @import("std");

pub const native_format = "unpolished-peas-scene";
pub const native_version: u32 = 1;

pub const Metadata = struct {
    name: []const u8,
    tags: []const []const u8,
};

pub const Component = struct {
    kind: []const u8,
};

pub const Reference = struct {
    name: []const u8,
    target: []const u8,
};

pub const Entity = struct {
    id: []const u8,
    name: []const u8,
    parent: ?[]const u8 = null,
    binding: ?[]const u8 = null,
    components: []const Component,
    references: []const Reference,
};

pub const Source = struct {
    format: []const u8,
    version: u32,
    metadata: Metadata,
    entities: []const Entity,

    pub fn deinit(self: *Source, allocator: std.mem.Allocator) void {
        std.zon.parse.free(allocator, self.*);
        self.* = undefined;
    }

    pub fn encode(self: Source, allocator: std.mem.Allocator) ![]u8 {
        var output = std.Io.Writer.Allocating.init(allocator);
        defer output.deinit();
        try std.zon.stringify.serialize(self, .{}, &output.writer);
        return allocator.dupe(u8, output.written());
    }
};

pub const Diagnostic = struct {
    line: usize = 1,
    column: usize = 1,
    message: []const u8 = "invalid scene",
};

pub fn parse(allocator: std.mem.Allocator, source: []const u8, diagnostic: *Diagnostic) !Source {
    const zon_source = try allocator.dupeZ(u8, source);
    defer allocator.free(zon_source);
    var zon_diagnostics: std.zon.parse.Diagnostics = .{};
    defer zon_diagnostics.deinit(allocator);
    var parsed = std.zon.parse.fromSlice(Source, allocator, zon_source, &zon_diagnostics, .{ .ignore_unknown_fields = false }) catch |err| switch (err) {
        error.ParseZon => {
            var errors = zon_diagnostics.iterateErrors();
            if (errors.next()) |parse_error| {
                const location = parse_error.getLocation(&zon_diagnostics);
                diagnostic.* = .{ .line = location.line + 1, .column = location.column + 1, .message = "invalid scene" };
            }
            return err;
        },
        else => return err,
    };
    errdefer parsed.deinit(allocator);
    try validate(parsed, source, diagnostic);
    return parsed;
}

pub fn load(allocator: std.mem.Allocator, source: []const u8) !Source {
    var diagnostic = Diagnostic{};
    return parse(allocator, source, &diagnostic);
}

fn validate(scene: Source, source: []const u8, diagnostic: *Diagnostic) !void {
    if (!std.mem.eql(u8, scene.format, native_format)) return fail(diagnostic, source, "format", "unsupported scene format");
    if (scene.version != native_version) return fail(diagnostic, source, "version", "unsupported scene version");
    if (scene.metadata.name.len == 0) return fail(diagnostic, source, "metadata", "scene metadata requires a name");
    try validateSortedStrings(scene.metadata.tags, source, "tags", diagnostic);
    for (scene.entities, 0..) |entity, index| {
        if (entity.id.len == 0 or entity.name.len == 0) return fail(diagnostic, source, "id", "entities require nonempty id and name");
        if (index != 0 and std.mem.order(u8, scene.entities[index - 1].id, entity.id) != .lt) return fail(diagnostic, source, "id", "entity ids must be unique and sorted");
        if (entity.binding) |binding| if (binding.len == 0) return fail(diagnostic, source, "binding", "gameplay binding cannot be empty");
        if (entity.parent) |parent| {
            if (std.mem.eql(u8, parent, entity.id) or !hasEntity(scene.entities, parent)) return fail(diagnostic, source, "parent", "parent references an unknown entity");
        }
        try validateComponents(entity.components, source, diagnostic);
        for (entity.references, 0..) |reference, reference_index| {
            if (reference.name.len == 0 or reference.target.len == 0 or !hasEntity(scene.entities, reference.target)) return fail(diagnostic, source, "target", "reference targets an unknown entity");
            if (reference_index != 0 and std.mem.order(u8, entity.references[reference_index - 1].name, reference.name) != .lt) return fail(diagnostic, source, "references", "reference names must be unique and sorted");
        }
    }
}

fn validateSortedStrings(items: []const []const u8, source: []const u8, field: []const u8, diagnostic: *Diagnostic) !void {
    for (items, 0..) |item, index| {
        if (item.len == 0 or (index != 0 and std.mem.order(u8, items[index - 1], item) != .lt)) return fail(diagnostic, source, field, "values must be nonempty, unique, and sorted");
    }
}

fn validateComponents(components: []const Component, source: []const u8, diagnostic: *Diagnostic) !void {
    for (components, 0..) |component, index| {
        if (component.kind.len == 0 or (index != 0 and std.mem.order(u8, components[index - 1].kind, component.kind) != .lt)) return fail(diagnostic, source, "components", "component kinds must be nonempty, unique, and sorted");
    }
}

fn hasEntity(entities: []const Entity, id: []const u8) bool {
    for (entities) |entity| if (std.mem.eql(u8, entity.id, id)) return true;
    return false;
}

fn fail(diagnostic: *Diagnostic, source: []const u8, field: []const u8, message: []const u8) error{InvalidScene} {
    diagnostic.* = .{ .line = fieldLocation(source, field).line, .column = fieldLocation(source, field).column, .message = message };
    return error.InvalidScene;
}

fn fieldLocation(source: []const u8, field: []const u8) struct { line: usize, column: usize } {
    const offset = std.mem.indexOf(u8, source, field) orelse return .{ .line = 1, .column = 1 };
    var line: usize = 1;
    var column: usize = 1;
    for (source[0..offset]) |byte| {
        if (byte == '\n') {
            line += 1;
            column = 1;
        } else column += 1;
    }
    return .{ .line = line, .column = column };
}

test "native scene parses, validates references, and round trips" {
    const fixture = try std.fs.cwd().readFileAlloc(std.testing.allocator, "fixtures/scenes/main.upscene", 64 * 1024);
    defer std.testing.allocator.free(fixture);
    var diagnostic = Diagnostic{};
    var scene = try parse(std.testing.allocator, fixture, &diagnostic);
    defer scene.deinit(std.testing.allocator);
    const encoded = try scene.encode(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    var decoded = try parse(std.testing.allocator, encoded, &diagnostic);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(scene.metadata.name, decoded.metadata.name);
    try std.testing.expectEqualStrings(scene.entities[1].id, decoded.entities[1].id);
}

test "native scene reports invalid reference locations" {
    const fixture =
        \\.{
        \\    .format = "unpolished-peas-scene",
        \\    .version = 1,
        \\    .metadata = .{ .name = "main", .tags = .{} },
        \\    .entities = .{ .{ .id = "player", .name = "Player", .components = .{}, .references = .{ .{ .name = "target", .target = "missing" } } } },
        \\}
        \\
    ;
    var diagnostic = Diagnostic{};
    try std.testing.expectError(error.InvalidScene, parse(std.testing.allocator, fixture, &diagnostic));
    try std.testing.expect(diagnostic.line > 1 and diagnostic.column > 0);
    try std.testing.expectEqualStrings("reference targets an unknown entity", diagnostic.message);
}
