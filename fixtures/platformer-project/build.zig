const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize }) });
    const run = b.addRunArtifact(tests);
    inline for (.{ "test", "test-replay", "test-visual", "test-integration" }) |name| {
        const step = b.step(name, "Run native platformer fixture coverage");
        step.dependOn(&run.step);
    }
}
