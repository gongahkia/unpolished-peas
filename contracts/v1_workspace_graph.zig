const std = @import("std");
const boundary = @import("v1_module_boundary.zig");

pub const PackageSpec = struct {
    id: boundary.Package,
    dependency_name: []const u8,
    module_name: []const u8,
    root_source_path: []const u8,
    test_artifact_name: []const u8,
};

pub const packages = [_]PackageSpec{
    .{ .id = .core, .dependency_name = "core", .module_name = "minna-san-core", .root_source_path = "packages/core/src/core.zig", .test_artifact_name = "core-tests" },
    .{ .id = .protocol, .dependency_name = "protocol", .module_name = "minna-san-protocol", .root_source_path = "packages/protocol/src/protocol.zig", .test_artifact_name = "protocol-tests" },
    .{ .id = .transport, .dependency_name = "transport", .module_name = "minna-san-transport", .root_source_path = "packages/transport/src/transport.zig", .test_artifact_name = "transport-tests" },
    .{ .id = .topology, .dependency_name = "topology", .module_name = "minna-san-topology", .root_source_path = "packages/topology/src/topology.zig", .test_artifact_name = "topology-tests" },
    .{ .id = .state, .dependency_name = "state", .module_name = "minna-san-state", .root_source_path = "packages/state/src/state.zig", .test_artifact_name = "state-tests" },
    .{ .id = .runtime, .dependency_name = "runtime", .module_name = "minna-san-runtime", .root_source_path = "packages/runtime/src/runtime.zig", .test_artifact_name = "runtime-tests" },
    .{ .id = .c_abi, .dependency_name = "c_abi", .module_name = "minna-san-c-abi", .root_source_path = "packages/c-abi/src/c_abi.zig", .test_artifact_name = "c-abi-tests" },
    .{ .id = .optional_reference, .dependency_name = "optional_reference", .module_name = "minna-san-optional-reference", .root_source_path = "packages/optional-reference/src/optional_reference.zig", .test_artifact_name = "optional-reference-tests" },
};

pub fn package(id: boundary.Package) *const PackageSpec {
    inline for (&packages) |*spec| {
        if (spec.id == id) return spec;
    }
    unreachable;
}

test "workspace graph declares each v1 package exactly once" {
    try std.testing.expectEqual(@as(usize, @typeInfo(boundary.Package).@"enum".fields.len), packages.len);
    inline for (std.meta.fields(boundary.Package)) |field| {
        const id: boundary.Package = @enumFromInt(field.value);
        const spec = package(id);
        try std.testing.expectEqual(id, spec.id);
        try std.testing.expect(spec.dependency_name.len != 0);
        try std.testing.expect(spec.module_name.len != 0);
        try std.testing.expect(spec.root_source_path.len != 0);
        try std.testing.expect(spec.test_artifact_name.len != 0);
    }
}

test "workspace graph preserves every permitted and rejected edge" {
    for (boundary.allowed_imports) |edge| try std.testing.expect(boundary.allows(edge.importer, edge.imported));
    try std.testing.expect(!boundary.allows(.core, .runtime));
    try std.testing.expect(!boundary.allows(.protocol, .transport));
    try std.testing.expect(!boundary.allows(.c_abi, .optional_reference));
}
