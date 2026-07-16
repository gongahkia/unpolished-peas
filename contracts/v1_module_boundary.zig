const std = @import("std");

pub const Package = enum {
    core,
    protocol,
    transport,
    topology,
    state,
    runtime,
    c_abi,
    optional_reference,
};

pub const Import = struct {
    importer: Package,
    imported: Package,
};

pub const allowed_imports = [_]Import{
    .{ .importer = .protocol, .imported = .core },
    .{ .importer = .transport, .imported = .core },
    .{ .importer = .transport, .imported = .protocol },
    .{ .importer = .topology, .imported = .core },
    .{ .importer = .topology, .imported = .protocol },
    .{ .importer = .topology, .imported = .transport },
    .{ .importer = .state, .imported = .core },
    .{ .importer = .state, .imported = .protocol },
    .{ .importer = .runtime, .imported = .core },
    .{ .importer = .runtime, .imported = .protocol },
    .{ .importer = .runtime, .imported = .transport },
    .{ .importer = .runtime, .imported = .topology },
    .{ .importer = .runtime, .imported = .state },
    .{ .importer = .c_abi, .imported = .core },
    .{ .importer = .c_abi, .imported = .runtime },
    .{ .importer = .optional_reference, .imported = .core },
    .{ .importer = .optional_reference, .imported = .protocol },
    .{ .importer = .optional_reference, .imported = .transport },
    .{ .importer = .optional_reference, .imported = .topology },
    .{ .importer = .optional_reference, .imported = .state },
    .{ .importer = .optional_reference, .imported = .runtime },
    .{ .importer = .optional_reference, .imported = .c_abi },
};

pub fn allows(importer: Package, imported: Package) bool {
    if (importer == imported) return true;
    for (allowed_imports) |entry| {
        if (entry.importer == importer and entry.imported == imported) return true;
    }
    return false;
}

pub fn requireImport(comptime importer: Package, comptime imported: Package) void {
    if (!allows(importer, imported)) {
        @compileError(std.fmt.comptimePrint("v1 boundary rejects {s} importing {s}", .{ @tagName(importer), @tagName(imported) }));
    }
}

test "v1 boundary permits only declared imports" {
    inline for (std.meta.fields(Package)) |importer_field| {
        inline for (std.meta.fields(Package)) |imported_field| {
            const importer: Package = @enumFromInt(importer_field.value);
            const imported: Package = @enumFromInt(imported_field.value);
            const expected = importer == imported or blk: {
                for (allowed_imports) |entry| {
                    if (entry.importer == importer and entry.imported == imported) break :blk true;
                }
                break :blk false;
            };
            try std.testing.expectEqual(expected, allows(importer, imported));
        }
    }
}

test "v1 boundary rejects upward and optional-reference imports" {
    try std.testing.expect(!allows(.core, .runtime));
    try std.testing.expect(!allows(.protocol, .transport));
    try std.testing.expect(!allows(.transport, .topology));
    try std.testing.expect(!allows(.topology, .runtime));
    try std.testing.expect(!allows(.state, .runtime));
    try std.testing.expect(!allows(.runtime, .c_abi));
    try std.testing.expect(!allows(.c_abi, .optional_reference));
}
