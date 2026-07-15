const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const effects = b.addModule("unpolished-peas-effects", .{
        .root_source_file = b.path("src/effects.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = effects });
    const run = b.addRunArtifact(tests);
    const step = b.step("test", "Test the unpolished-peas effects package");
    step.dependOn(&run.step);
}
