const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const peas = b.dependency("unpolished_peas", .{ .target = target, .optimize = optimize });
    const ecs = b.dependency("unpolished_peas_ecs", .{ .target = target, .optimize = optimize });
    const networking = b.dependency("unpolished_peas_networking", .{ .target = target, .optimize = optimize });
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/modules.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "unpolished-peas", .module = peas.module("unpolished-peas") },
                .{ .name = "unpolished-peas-ecs", .module = ecs.module("unpolished-peas-ecs") },
                .{ .name = "unpolished-peas-networking", .module = networking.module("unpolished-peas-networking") },
                .{ .name = "unpolished-peas-tools", .module = peas.module("unpolished-peas-tools") },
                .{ .name = "unpolished-peas-services", .module = peas.module("unpolished-peas-services") },
            },
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Compile downstream core, tools, and services modules without SDL");
    test_step.dependOn(&run_tests.step);
}
