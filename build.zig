const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("unpolished", .{
        .root_source_file = b.path("src/unpolished.zig"),
        .target = target,
        .optimize = optimize,
    });
    addStb(mod);

    const sdl_mod = b.addModule("unpolished_sdl3", .{
        .root_source_file = b.path("src/backend/sdl_gpu.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "unpolished", .module = mod },
        },
    });
    addSdl3(sdl_mod);

    const lib = b.addLibrary(.{
        .name = "unpolished",
        .linkage = .static,
        .root_module = mod,
    });
    b.installArtifact(lib);

    const demo = b.addExecutable(.{
        .name = "bounce",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/bounce.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "unpolished", .module = mod },
            },
        }),
    });
    b.installArtifact(demo);

    const sdl_demo = b.addExecutable(.{
        .name = "bounce-sdl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/bounce_sdl.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "unpolished", .module = mod },
                .{ .name = "unpolished_sdl3", .module = sdl_mod },
            },
        }),
    });
    b.installArtifact(sdl_demo);

    const dev_demo = b.addExecutable(.{
        .name = "dev-bounce",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/dev_bounce.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "unpolished", .module = mod },
                .{ .name = "unpolished_sdl3", .module = sdl_mod },
            },
        }),
    });
    b.installArtifact(dev_demo);

    const minimal_demo = b.addExecutable(.{
        .name = "minimal",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/minimal.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "unpolished", .module = mod },
                .{ .name = "unpolished_sdl3", .module = sdl_mod },
            },
        }),
    });
    b.installArtifact(minimal_demo);

    const scene_tests = b.addExecutable(.{
        .name = "test-scenes",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/test_scenes.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "unpolished", .module = mod },
            },
        }),
    });

    const run_demo = b.addRunArtifact(demo);

    const run_step = b.step("run-bounce", "Render the bounce demo to zig-out/bounce.ppm");
    run_step.dependOn(&run_demo.step);

    const run_sdl_demo = b.addRunArtifact(sdl_demo);
    if (b.args) |args| run_sdl_demo.addArgs(args);

    const run_sdl_step = b.step("run-bounce-sdl", "Run the SDL_GPU bounce demo");
    run_sdl_step.dependOn(&run_sdl_demo.step);

    const run_dev_demo = b.addRunArtifact(dev_demo);
    if (b.args) |args| run_dev_demo.addArgs(args);

    const run_dev_step = b.step("dev-bounce", "Run the live-reload SDL_GPU bounce demo");
    run_dev_step.dependOn(&run_dev_demo.step);

    const run_minimal_demo = b.addRunArtifact(minimal_demo);
    if (b.args) |args| run_minimal_demo.addArgs(args);

    const run_minimal_step = b.step("run-minimal", "Run the minimal SDL_GPU demo");
    run_minimal_step.dependOn(&run_minimal_demo.step);

    const run_scene_tests = b.addRunArtifact(scene_tests);
    const scene_step = b.step("test-scenes", "Run deterministic scene hash tests");
    scene_step.dependOn(&run_scene_tests.step);

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}

fn addStb(mod: *std.Build.Module) void {
    mod.link_libc = true;
    mod.addIncludePath(.{ .cwd_relative = "vendor/stb" });
    mod.addCSourceFile(.{
        .file = .{ .cwd_relative = "src/vendor/stb_image.c" },
        .flags = &.{"-std=c99"},
    });
}

fn addSdl3(mod: *std.Build.Module) void {
    mod.link_libc = true;
    mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    mod.addRPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    mod.linkSystemLibrary("SDL3", .{});
}
