const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const networking_dependency = b.lazyDependency("networking", .{ .target = target, .optimize = optimize }) orelse @panic("missing networking package");
    const services = b.addModule("unpolished-peas-services", .{
        .root_source_file = b.path("src/services.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "unpolished-peas-networking", .module = networking_dependency.module("unpolished-peas-networking") }},
    });
    const tests = b.addTest(.{ .root_module = services });
    const run = b.addRunArtifact(tests);
    const step = b.step("test", "Test the unpolished-peas services package");
    step.dependOn(&run.step);
}
