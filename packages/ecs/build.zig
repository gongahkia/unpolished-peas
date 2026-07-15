const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const ecs = b.addModule("unpolished-peas-ecs", .{
        .root_source_file = b.path("src/ecs.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = ecs });
    const run = b.addRunArtifact(tests);
    const step = b.step("test", "Test the unpolished-peas ECS package");
    step.dependOn(&run.step);
}
