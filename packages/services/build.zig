const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const core_dependency = b.lazyDependency("core", .{ .target = target, .optimize = optimize }) orelse @panic("missing minna-san core package");
    const networking_dependency = b.lazyDependency("networking", .{ .target = target, .optimize = optimize }) orelse @panic("missing minna-san networking package");
    const services = b.addModule("minna-san-services", .{
        .root_source_file = b.path("src/services.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "minna-san-core", .module = core_dependency.module("minna-san-core") },
            .{ .name = "minna-san-networking", .module = networking_dependency.module("minna-san-networking") },
        },
    });
    const tests = b.addTest(.{ .root_module = services });
    const run = b.addRunArtifact(tests);
    const test_step = b.step("test", "Test the minna-san services package");
    test_step.dependOn(&run.step);
}
