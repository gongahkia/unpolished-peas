const std = @import("std");
const boundary = @import("v1_module_boundary.zig");

pub const PackageSpec = struct {
    id: boundary.Package,
    dependency_name: []const u8,
    module_name: []const u8,
    root_source_path: []const u8,
    test_artifact_name: []const u8,
    imports: []const boundary.Package,
};

pub const packages = [_]PackageSpec{
    .{ .id = .core, .dependency_name = "core", .module_name = "minna-san-core", .root_source_path = "packages/core/src/core.zig", .test_artifact_name = "core-tests", .imports = &.{} },
    .{ .id = .protocol, .dependency_name = "protocol", .module_name = "minna-san-protocol", .root_source_path = "packages/protocol/src/protocol.zig", .test_artifact_name = "protocol-tests", .imports = &.{.core} },
    .{ .id = .transport, .dependency_name = "transport", .module_name = "minna-san-transport", .root_source_path = "packages/transport/src/transport.zig", .test_artifact_name = "transport-tests", .imports = &.{ .core, .protocol } },
    .{ .id = .topology, .dependency_name = "topology", .module_name = "minna-san-topology", .root_source_path = "packages/topology/src/topology.zig", .test_artifact_name = "topology-tests", .imports = &.{ .core, .protocol, .transport } },
    .{ .id = .state, .dependency_name = "state", .module_name = "minna-san-state", .root_source_path = "packages/state/src/state.zig", .test_artifact_name = "state-tests", .imports = &.{ .core, .protocol } },
    .{ .id = .runtime, .dependency_name = "runtime", .module_name = "minna-san-runtime", .root_source_path = "packages/runtime/src/runtime.zig", .test_artifact_name = "runtime-tests", .imports = &.{ .core, .protocol, .transport, .topology, .state } },
    .{ .id = .c_abi, .dependency_name = "c_abi", .module_name = "minna-san-c-abi", .root_source_path = "packages/c-abi/src/c_abi.zig", .test_artifact_name = "c-abi-tests", .imports = &.{ .core, .runtime } },
    .{ .id = .optional_reference, .dependency_name = "optional_reference", .module_name = "minna-san-optional-reference", .root_source_path = "packages/optional-reference/src/optional_reference.zig", .test_artifact_name = "optional-reference-tests", .imports = &.{ .core, .protocol, .transport, .topology, .state, .runtime, .c_abi } },
    .{ .id = .networking, .dependency_name = "networking", .module_name = "minna-san-networking", .root_source_path = "packages/networking/src/networking.zig", .test_artifact_name = "networking-tests", .imports = &.{} },
    .{ .id = .services, .dependency_name = "services", .module_name = "minna-san-services", .root_source_path = "packages/services/src/services.zig", .test_artifact_name = "services-tests", .imports = &.{ .core, .networking } },
};

pub fn package(id: boundary.Package) *const PackageSpec {
    inline for (&packages) |*spec| {
        if (spec.id == id) return spec;
    }
    unreachable;
}

fn packageIndex(id: boundary.Package) usize {
    for (packages, 0..) |spec, index| {
        if (spec.id == id) return index;
    }
    unreachable;
}

pub fn moduleSlot(id: boundary.Package) usize {
    return packageIndex(id);
}

pub fn moduleImports(b: *std.Build, importer: boundary.Package, modules: []const ?*std.Build.Module) []std.Build.Module.Import {
    const dependencies = package(importer).imports;
    const imports = b.allocator.alloc(std.Build.Module.Import, dependencies.len) catch @panic("out of memory");
    for (dependencies, 0..) |dependency, index| {
        const module = modules[packageIndex(dependency)] orelse @panic("workspace module was created out of dependency order");
        imports[index] = .{ .name = package(dependency).module_name, .module = module };
    }
    return imports;
}

test "workspace graph declares each package exactly once" {
    try std.testing.expectEqual(@as(usize, @typeInfo(boundary.Package).@"enum".fields.len), packages.len);
    inline for (std.meta.fields(boundary.Package)) |field| {
        const id: boundary.Package = @enumFromInt(field.value);
        const spec = package(id);
        try std.testing.expectEqual(id, spec.id);
        try std.testing.expect(spec.dependency_name.len != 0);
        try std.testing.expect(spec.module_name.len != 0);
        try std.testing.expect(spec.root_source_path.len != 0);
        try std.testing.expect(spec.test_artifact_name.len != 0);
        try std.testing.expectEqual(spec.id, packages[packageIndex(id)].id);
    }
}

test "workspace graph accepts only documented module edges" {
    inline for (std.meta.fields(boundary.Package)) |importer_field| {
        inline for (std.meta.fields(boundary.Package)) |imported_field| {
            const importer: boundary.Package = @enumFromInt(importer_field.value);
            const imported: boundary.Package = @enumFromInt(imported_field.value);
            const declared = for (package(importer).imports) |dependency| {
                if (dependency == imported) break true;
            } else false;
            try std.testing.expectEqual(importer == imported or declared, boundary.allows(importer, imported));
        }
    }
    try std.testing.expect(!boundary.allows(.core, .runtime));
    try std.testing.expect(!boundary.allows(.protocol, .transport));
    try std.testing.expect(!boundary.allows(.c_abi, .optional_reference));
}
