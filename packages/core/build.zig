const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("minna-san-core", .{ .root_source_file = b.path("src/core.zig"), .target = target, .optimize = optimize });
    const tests = b.addTest(.{ .root_module = module });
    const run = b.addRunArtifact(tests);
    const test_step = b.step("test", "Test the minna-san core package");
    test_step.dependOn(&run.step);
}
