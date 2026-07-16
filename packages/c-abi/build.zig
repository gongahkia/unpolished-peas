const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const core_dependency = b.lazyDependency("core", .{ .target = target, .optimize = optimize }) orelse @panic("missing minna-san core package");
    const runtime_dependency = b.lazyDependency("runtime", .{ .target = target, .optimize = optimize }) orelse @panic("missing minna-san runtime package");
    const module = b.addModule("minna-san-c-abi", .{
        .root_source_file = b.path("src/c_abi.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "minna-san-core", .module = core_dependency.module("minna-san-core") },
            .{ .name = "minna-san-runtime", .module = runtime_dependency.module("minna-san-runtime") },
        },
    });
    const tests = b.addTest(.{ .root_module = module });
    const run = b.addRunArtifact(tests);
    const test_step = b.step("test", "Test the minna-san C ABI package");
    test_step.dependOn(&run.step);
}
