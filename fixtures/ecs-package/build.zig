const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const ecs = b.dependency("unpolished_peas_ecs", .{ .target = target, .optimize = optimize });
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "unpolished-peas-ecs", .module = ecs.module("unpolished-peas-ecs") }},
    }) });
    const run = b.addRunArtifact(tests);
    const step = b.step("test", "Test the external ECS package fixture");
    step.dependOn(&run.step);
}
