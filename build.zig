const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const boundary = b.createModule(.{
        .root_source_file = b.path("contracts/v1_module_boundary.zig"),
        .target = target,
        .optimize = optimize,
    });
    const networking_dependency = b.lazyDependency("networking", .{ .target = target, .optimize = optimize }) orelse @panic("missing minna-san networking package");
    const services_dependency = b.lazyDependency("services", .{ .target = target, .optimize = optimize }) orelse @panic("missing minna-san services package");
    const networking = networking_dependency.module("minna-san-networking");
    const services = services_dependency.module("minna-san-services");
    const boundary_tests = b.addTest(.{ .root_module = boundary });
    const boundary_verifier = b.addExecutable(.{
        .name = "verify-forbidden-import",
        .root_module = b.createModule(.{
            .root_source_file = b.path("contracts/verify_forbidden_import.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const networking_tests = b.addTest(.{ .root_module = networking });
    const services_tests = b.addTest(.{ .root_module = services });
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
    const run_networking = b.addRunArtifact(networking_tests);
    const run_services = b.addRunArtifact(services_tests);
    const boundary_step = b.step("contract", "Check the v1 module boundary");
    boundary_step.dependOn(&run_boundary.step);
    boundary_step.dependOn(&run_boundary_verifier.step);
    const test_step = b.step("test", "Test v1 contracts, networking, and services modules");
    test_step.dependOn(&run_boundary.step);
    test_step.dependOn(&run_boundary_verifier.step);
    test_step.dependOn(&run_networking.step);
    test_step.dependOn(&run_services.step);
}
