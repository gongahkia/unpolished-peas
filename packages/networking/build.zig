const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const networking = b.addModule("unpolished-peas-networking", .{ .root_source_file = b.path("src/networking.zig"), .target = target, .optimize = optimize });
    const tests = b.addTest(.{ .root_module = networking });
    const run = b.addRunArtifact(tests);
    const step = b.step("test", "Test the unpolished-peas networking package");
    step.dependOn(&run.step);
}
