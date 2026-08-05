const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const core_dependency = b.lazyDependency("core", .{ .target = target, .optimize = optimize }) orelse @panic("missing minna-san core package");
    const protocol_dependency = b.lazyDependency("protocol", .{ .target = target, .optimize = optimize }) orelse @panic("missing minna-san protocol package");
    const transport_dependency = b.lazyDependency("transport", .{ .target = target, .optimize = optimize }) orelse @panic("missing minna-san transport package");
    const topology_dependency = b.lazyDependency("topology", .{ .target = target, .optimize = optimize }) orelse @panic("missing minna-san topology package");
    const state_dependency = b.lazyDependency("state", .{ .target = target, .optimize = optimize }) orelse @panic("missing minna-san state package");
    const module = b.addModule("minna-san-runtime", .{
        .root_source_file = b.path("src/runtime.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "minna-san-core", .module = core_dependency.module("minna-san-core") },
            .{ .name = "minna-san-protocol", .module = protocol_dependency.module("minna-san-protocol") },
            .{ .name = "minna-san-transport", .module = transport_dependency.module("minna-san-transport") },
            .{ .name = "minna-san-topology", .module = topology_dependency.module("minna-san-topology") },
            .{ .name = "minna-san-state", .module = state_dependency.module("minna-san-state") },
        },
    });
    const tests = b.addTest(.{ .root_module = module });
    const run = b.addRunArtifact(tests);
    const test_step = b.step("test", "Test the minna-san runtime package");
    test_step.dependOn(&run.step);
}
