const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const ui = b.addModule("unpolished-peas-ui", .{
        .root_source_file = b.path("src/ui.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = ui });
    const run = b.addRunArtifact(tests);
    const step = b.step("test", "Test the unpolished-peas UI package");
    step.dependOn(&run.step);
}
