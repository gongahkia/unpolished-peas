const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const peas = b.dependency("unpolished_peas", .{ .target = target, .optimize = optimize });
    const install_assets = b.addInstallDirectory(.{
        .source_dir = b.path("assets"),
        .install_dir = .prefix,
        .install_subdir = "assets",
    });
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "unpolished-peas", .module = peas.module("unpolished-peas") },
            .{ .name = "unpolished-peas-sdl3", .module = peas.module("unpolished-peas-sdl3") },
        },
    });
    const exe = b.addExecutable(.{ .name = "external-tilemap-camera-actions", .root_module = module });
    b.installArtifact(exe);
    b.getInstallStep().dependOn(&install_assets.step);
    const run = b.addRunArtifact(exe);
    run.setEnvironmentVariable("UP_ASSET_ROOT", b.pathFromRoot("assets"));
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Run the bounded external tile-map fixture");
    run_step.dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Test the external tile-map fixture");
    test_step.dependOn(&run_tests.step);
}
