const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const effects = b.dependency("unpolished_peas_effects", .{ .target = target, .optimize = optimize });
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "unpolished-peas-effects", .module = effects.module("unpolished-peas-effects") }},
    });
    const tests = b.addTest(.{ .root_module = module });
    const run = b.addRunArtifact(tests);
    const step = b.step("test", "Test the external effects package fixture");
    step.dependOn(&run.step);
}
