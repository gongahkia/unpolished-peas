const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const boundary = b.createModule(.{
        .root_source_file = b.path("contracts/v1_module_boundary.zig"),
        .target = target,
        .optimize = optimize,
    });
    const core_dependency = b.lazyDependency("core", .{ .target = target, .optimize = optimize }) orelse @panic("missing minna-san core package");
    const networking_dependency = b.lazyDependency("networking", .{ .target = target, .optimize = optimize }) orelse @panic("missing minna-san networking package");
    const protocol_dependency = b.lazyDependency("protocol", .{ .target = target, .optimize = optimize }) orelse @panic("missing minna-san protocol package");
    const services_dependency = b.lazyDependency("services", .{ .target = target, .optimize = optimize }) orelse @panic("missing minna-san services package");
    const state_dependency = b.lazyDependency("state", .{ .target = target, .optimize = optimize }) orelse @panic("missing minna-san state package");
    const topology_dependency = b.lazyDependency("topology", .{ .target = target, .optimize = optimize }) orelse @panic("missing minna-san topology package");
    const transport_dependency = b.lazyDependency("transport", .{ .target = target, .optimize = optimize }) orelse @panic("missing minna-san transport package");
    const runtime_dependency = b.lazyDependency("runtime", .{ .target = target, .optimize = optimize }) orelse @panic("missing minna-san runtime package");
    const c_abi_dependency = b.lazyDependency("c_abi", .{ .target = target, .optimize = optimize }) orelse @panic("missing minna-san C ABI package");
    const optional_reference_dependency = b.lazyDependency("optional_reference", .{ .target = target, .optimize = optimize }) orelse @panic("missing minna-san optional-reference package");
    const core = core_dependency.module("minna-san-core");
    const networking = networking_dependency.module("minna-san-networking");
    const protocol = protocol_dependency.module("minna-san-protocol");
    const services = services_dependency.module("minna-san-services");
    const state = state_dependency.module("minna-san-state");
    const topology = topology_dependency.module("minna-san-topology");
    const transport = transport_dependency.module("minna-san-transport");
    const runtime = runtime_dependency.module("minna-san-runtime");
    const c_abi = c_abi_dependency.module("minna-san-c-abi");
    const optional_reference = optional_reference_dependency.module("minna-san-optional-reference");
    const boundary_tests = b.addTest(.{ .root_module = boundary });
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
    const test_step = b.step("test", "Test v1 packages and contracts");
    test_step.dependOn(&run_boundary.step);
    test_step.dependOn(&run_boundary_verifier.step);
    test_step.dependOn(&run_core.step);
    test_step.dependOn(&run_networking.step);
    test_step.dependOn(&run_protocol.step);
    test_step.dependOn(&run_services.step);
    test_step.dependOn(&run_state.step);
    test_step.dependOn(&run_topology.step);
    test_step.dependOn(&run_transport.step);
    test_step.dependOn(&run_runtime.step);
    test_step.dependOn(&run_c_abi.step);
    test_step.dependOn(&run_optional_reference.step);
}
