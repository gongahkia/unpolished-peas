const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const peas = b.dependency("unpolished_peas", .{ .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{
        .name = "downstream-headless",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "unpolished-peas", .module = peas.module("unpolished-peas") },
                .{ .name = "unpolished-peas-sdl3", .module = peas.module("unpolished-peas-sdl3") },
            },
        }),
    });
    const run = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the bounded downstream headless fixture");
    run_step.dependOn(&run.step);
}
