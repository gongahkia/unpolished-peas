const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const core_dependency = b.lazyDependency("core", .{ .target = target, .optimize = optimize }) orelse @panic("missing minna-san core package");
    const module = b.addModule("minna-san-protocol", .{
        .root_source_file = b.path("src/protocol.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "minna-san-core", .module = core_dependency.module("minna-san-core") }},
    });
    const tests = b.addTest(.{ .root_module = module });
    const run = b.addRunArtifact(tests);
    const test_step = b.step("test", "Test the minna-san protocol package");
    test_step.dependOn(&run.step);
}
