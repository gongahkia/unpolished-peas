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
    const exe = b.addExecutable(.{ .name = "facade-desktop-consumer", .root_module = module });
    b.installArtifact(exe);
    const tests = b.addTest(.{ .root_module = module });
    const run = b.addRunArtifact(tests);
    const test_step = b.step("test", "Test the independent desktop facade consumer");
    test_step.dependOn(&run.step);
}
