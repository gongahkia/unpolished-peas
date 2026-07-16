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
    const exe = b.addExecutable(.{ .name = "release-candidate-consumer", .root_module = module });
    const run = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the clean release candidate consumer");
    run_step.dependOn(&run.step);
}
