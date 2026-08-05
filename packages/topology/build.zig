const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const core_dependency = b.lazyDependency("core", .{ .target = target, .optimize = optimize }) orelse @panic("missing minna-san core package");
    const protocol_dependency = b.lazyDependency("protocol", .{ .target = target, .optimize = optimize }) orelse @panic("missing minna-san protocol package");
    const transport_dependency = b.lazyDependency("transport", .{ .target = target, .optimize = optimize }) orelse @panic("missing minna-san transport package");
    const module = b.addModule("minna-san-topology", .{
        .root_source_file = b.path("src/topology.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "minna-san-core", .module = core_dependency.module("minna-san-core") },
            .{ .name = "minna-san-protocol", .module = protocol_dependency.module("minna-san-protocol") },
            .{ .name = "minna-san-transport", .module = transport_dependency.module("minna-san-transport") },
        },
    });
    const tests = b.addTest(.{ .root_module = module });
    const run = b.addRunArtifact(tests);
    const test_step = b.step("test", "Test the minna-san topology package");
    test_step.dependOn(&run.step);
}
