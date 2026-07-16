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
    const exe = b.addExecutable(.{
        .name = "bouncing-square",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "unpolished-peas", .module = peas.module("unpolished-peas") },
                .{ .name = "unpolished-peas-sdl3", .module = peas.module("unpolished-peas-sdl3") },
            },
        }),
    });
    b.installArtifact(exe);
    b.getInstallStep().dependOn(&install_assets.step);

    const run = b.addRunArtifact(exe);
    run.setEnvironmentVariable("UP_ASSET_ROOT", b.pathFromRoot("assets"));
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Run the bouncing-square game");
    run_step.dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = exe.root_module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run bouncing-square unit tests");
    test_step.dependOn(&run_tests.step);
}
