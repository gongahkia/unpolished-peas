const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const peas = b.dependency("unpolished_peas", .{ .target = target, .optimize = optimize, .with_sdl = false });
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "unpolished-peas", .module = peas.module("unpolished-peas") }},
    });
    const tests = b.addTest(.{ .root_module = module });
    const run = b.addRunArtifact(tests);
    const step = b.step("test", "Test the cohesive effects facade fixture");
    step.dependOn(&run.step);
}
