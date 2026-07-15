const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const with_box2d = b.option(bool, "with_box2d", "Resolve the Box2D dependency") orelse true;
    const physics = b.addModule("unpolished-peas-physics", .{
        .root_source_file = b.path("src/physics.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (with_box2d) addBox2d(physics, b.lazyDependency("box2d", .{ .target = target, .optimize = optimize }) orelse @panic("missing Box2D dependency"));
}

fn addBox2d(mod: *std.Build.Module, dependency: *std.Build.Dependency) void {
    mod.link_libc = true;
    mod.addIncludePath(dependency.path("include"));
    mod.linkLibrary(dependency.artifact("box2d"));
}
