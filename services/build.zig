const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const upstream = b.dependency("unpolished_peas_services", .{ .target = target, .optimize = optimize });
    const services = upstream.module("unpolished-peas-services");
    const runtime = b.addExecutable(.{
        .name = "unpolished-peas-services-local",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "unpolished-peas-services", .module = services }},
        }),
    });
    b.installArtifact(runtime);
    const run = b.addRunArtifact(runtime);
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Run the local online-services runtime");
    run_step.dependOn(&run.step);
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "unpolished-peas-services", .module = services }},
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Test local online-services configuration");
    test_step.dependOn(&run_tests.step);
}
