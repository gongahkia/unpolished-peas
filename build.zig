const std = @import("std");
const workspace = @import("contracts/v1_workspace_graph.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const boundary = b.createModule(.{
        .root_source_file = b.path("contracts/v1_module_boundary.zig"),
        .target = target,
        .optimize = optimize,
    });
    const workspace_graph = b.createModule(.{
        .root_source_file = b.path("contracts/v1_workspace_graph.zig"),
        .target = target,
        .optimize = optimize,
    });
    const core_spec = workspace.package(.core);
    const protocol_spec = workspace.package(.protocol);
    const transport_spec = workspace.package(.transport);
    const topology_spec = workspace.package(.topology);
    const state_spec = workspace.package(.state);
    const runtime_spec = workspace.package(.runtime);
    const c_abi_spec = workspace.package(.c_abi);
    const optional_reference_spec = workspace.package(.optional_reference);
    const core = b.createModule(.{
        .root_source_file = b.path(core_spec.root_source_path),
        .target = target,
        .optimize = optimize,
    });
    const protocol = b.createModule(.{
        .root_source_file = b.path(protocol_spec.root_source_path),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = core_spec.module_name, .module = core }},
    });
    const transport = b.createModule(.{
        .root_source_file = b.path(transport_spec.root_source_path),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = core_spec.module_name, .module = core },
            .{ .name = protocol_spec.module_name, .module = protocol },
        },
    });
    const topology = b.createModule(.{
        .root_source_file = b.path(topology_spec.root_source_path),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = core_spec.module_name, .module = core },
            .{ .name = protocol_spec.module_name, .module = protocol },
            .{ .name = transport_spec.module_name, .module = transport },
        },
    });
    const state = b.createModule(.{
        .root_source_file = b.path(state_spec.root_source_path),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = core_spec.module_name, .module = core },
            .{ .name = protocol_spec.module_name, .module = protocol },
        },
    });
    const runtime = b.createModule(.{
        .root_source_file = b.path(runtime_spec.root_source_path),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = core_spec.module_name, .module = core },
            .{ .name = protocol_spec.module_name, .module = protocol },
            .{ .name = transport_spec.module_name, .module = transport },
            .{ .name = topology_spec.module_name, .module = topology },
            .{ .name = state_spec.module_name, .module = state },
        },
    });
    const c_abi = b.createModule(.{
        .root_source_file = b.path(c_abi_spec.root_source_path),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = core_spec.module_name, .module = core },
            .{ .name = runtime_spec.module_name, .module = runtime },
        },
    });
    const optional_reference = b.createModule(.{
        .root_source_file = b.path(optional_reference_spec.root_source_path),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = core_spec.module_name, .module = core },
            .{ .name = protocol_spec.module_name, .module = protocol },
            .{ .name = transport_spec.module_name, .module = transport },
            .{ .name = topology_spec.module_name, .module = topology },
            .{ .name = state_spec.module_name, .module = state },
            .{ .name = runtime_spec.module_name, .module = runtime },
            .{ .name = c_abi_spec.module_name, .module = c_abi },
        },
    });
    const public_api = b.createModule(.{
        .root_source_file = b.path("contracts/v1_public_api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = core_spec.module_name, .module = core },
            .{ .name = protocol_spec.module_name, .module = protocol },
            .{ .name = transport_spec.module_name, .module = transport },
            .{ .name = topology_spec.module_name, .module = topology },
            .{ .name = state_spec.module_name, .module = state },
            .{ .name = runtime_spec.module_name, .module = runtime },
            .{ .name = c_abi_spec.module_name, .module = c_abi },
        },
    });
    const compatibility = b.createModule(.{
        .root_source_file = b.path("contracts/v1_compatibility.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = protocol_spec.module_name, .module = protocol }},
    });
    const naming = b.createModule(.{
        .root_source_file = b.path("contracts/v1_naming.zig"),
        .target = target,
        .optimize = optimize,
    });
    const networking = b.createModule(.{
        .root_source_file = b.path("packages/networking/src/networking.zig"),
        .target = target,
        .optimize = optimize,
    });
    const services = b.createModule(.{
        .root_source_file = b.path("packages/services/src/services.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "minna-san-networking", .module = networking }},
    });
    const boundary_tests = b.addTest(.{ .root_module = boundary });
    const workspace_graph_tests = b.addTest(.{ .root_module = workspace_graph });
    const public_api_tests = b.addTest(.{ .root_module = public_api });
    const compatibility_tests = b.addTest(.{ .root_module = compatibility });
    const naming_tests = b.addTest(.{ .root_module = naming });
    const boundary_verifier = b.addExecutable(.{
        .name = "verify-forbidden-import",
        .root_module = b.createModule(.{
            .root_source_file = b.path("contracts/verify_forbidden_import.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const core_tests = b.addTest(.{ .root_module = core });
    const networking_tests = b.addTest(.{ .root_module = networking });
    const protocol_tests = b.addTest(.{ .root_module = protocol });
    const services_tests = b.addTest(.{ .root_module = services });
    const state_tests = b.addTest(.{ .root_module = state });
    const topology_tests = b.addTest(.{ .root_module = topology });
    const transport_tests = b.addTest(.{ .root_module = transport });
    const runtime_tests = b.addTest(.{ .root_module = runtime });
    const c_abi_tests = b.addTest(.{ .root_module = c_abi });
    const optional_reference_tests = b.addTest(.{ .root_module = optional_reference });
    const run_boundary = b.addRunArtifact(boundary_tests);
    const run_workspace_graph = b.addRunArtifact(workspace_graph_tests);
    const run_public_api = b.addRunArtifact(public_api_tests);
    const run_compatibility = b.addRunArtifact(compatibility_tests);
    const run_naming = b.addRunArtifact(naming_tests);
    const run_boundary_verifier = b.addRunArtifact(boundary_verifier);
    run_boundary_verifier.setCwd(b.path("."));
    run_boundary_verifier.addArgs(&.{
        b.graph.zig_exe,
        "test",
        "--dep",
        "minna-san-core",
        "-Mroot=contracts/fixtures/forbidden_core_to_runtime.zig",
        "-Mminna-san-core=contracts/fixtures/allowed_core.zig",
    });
    const run_core = b.addRunArtifact(core_tests);
    const run_networking = b.addRunArtifact(networking_tests);
    const run_protocol = b.addRunArtifact(protocol_tests);
    const run_services = b.addRunArtifact(services_tests);
    const run_state = b.addRunArtifact(state_tests);
    const run_topology = b.addRunArtifact(topology_tests);
    const run_transport = b.addRunArtifact(transport_tests);
    const run_runtime = b.addRunArtifact(runtime_tests);
    const run_c_abi = b.addRunArtifact(c_abi_tests);
    const run_optional_reference = b.addRunArtifact(optional_reference_tests);
    const boundary_step = b.step("contract", "Check the v1 module boundary");
    boundary_step.dependOn(&run_boundary.step);
    boundary_step.dependOn(&run_boundary_verifier.step);
    const workspace_step = b.step("workspace-graph", "Check the explicit v1 workspace graph");
    workspace_step.dependOn(&run_workspace_graph.step);
    const api_step = b.step("api-contract", "Check the stable v1 public API");
    api_step.dependOn(&run_public_api.step);
    const compatibility_step = b.step("compatibility-contract", "Check stable API and wire compatibility");
    compatibility_step.dependOn(&run_public_api.step);
    compatibility_step.dependOn(&run_compatibility.step);
    const quality_check = b.addSystemCommand(&.{ "sh", "script/check_quality.sh" });
    const quality_step = b.step("quality", "Check formatting and source quality without rewrites");
    quality_step.dependOn(&quality_check.step);
    const quality_test = b.addSystemCommand(&.{ "sh", "script/test_quality_gate.sh" });
    const quality_test_step = b.step("quality-test", "Test the non-mutating quality gate");
    quality_test_step.dependOn(&quality_test.step);
    const dependency_check = b.addSystemCommand(&.{ "sh", "script/check_stdlib_only.sh" });
    const dependency_step = b.step("dependency-policy", "Check v1 sources use only std and first-party modules");
    dependency_step.dependOn(&dependency_check.step);
    const dependency_test = b.addSystemCommand(&.{ "sh", "script/test_stdlib_only.sh" });
    const dependency_test_step = b.step("dependency-policy-test", "Test the v1 dependency policy");
    dependency_test_step.dependOn(&dependency_test.step);
    const hermetic_test = b.addSystemCommand(&.{ "sh", "script/test_hermetic_build.sh" });
    const hermetic_step = b.step("hermetic-test", "Test SDK builds with an empty environment");
    hermetic_step.dependOn(&hermetic_test.step);
    const reference_test_step = b.step("reference-test", "Test optional networking and services references");
    reference_test_step.dependOn(&run_networking.step);
    reference_test_step.dependOn(&run_services.step);
    const c_header_check = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "cc",
        "-std=c11",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-c",
        "-o",
        ".zig-cache/c_abi_types.o",
        "-I",
        "packages/c-abi/include",
        "contracts/fixtures/c_abi_types.c",
    });
    const c_header_step = b.step("c-header-contract", "Check stable C ABI declarations compile as C11");
    c_header_step.dependOn(&c_header_check.step);
    const naming_step = b.step("naming-contract", "Check stable Zig and C naming rules");
    naming_step.dependOn(&run_naming.step);
    const test_step = b.step("test", "Test v1 packages and contracts");
    test_step.dependOn(&run_boundary.step);
    test_step.dependOn(&run_workspace_graph.step);
    test_step.dependOn(&run_public_api.step);
    test_step.dependOn(&run_compatibility.step);
    test_step.dependOn(&run_naming.step);
    test_step.dependOn(&run_boundary_verifier.step);
    test_step.dependOn(&run_core.step);
    test_step.dependOn(&run_protocol.step);
    test_step.dependOn(&run_state.step);
    test_step.dependOn(&run_topology.step);
    test_step.dependOn(&run_transport.step);
    test_step.dependOn(&run_runtime.step);
    test_step.dependOn(&run_c_abi.step);
    test_step.dependOn(&run_optional_reference.step);
    test_step.dependOn(&c_header_check.step);
}
