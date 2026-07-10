const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("unpolished", .{
        .root_source_file = b.path("src/unpolished.zig"),
        .target = target,
        .optimize = optimize,
    });
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

    const run_demo = b.addRunArtifact(demo);

    const run_step = b.step("run-bounce", "Render the bounce demo to zig-out/bounce.ppm");
    run_step.dependOn(&run_demo.step);

    const run_sdl_demo = b.addRunArtifact(sdl_demo);
    if (b.args) |args| run_sdl_demo.addArgs(args);

    const run_sdl_step = b.step("run-bounce-sdl", "Run the SDL_GPU bounce demo");
    run_sdl_step.dependOn(&run_sdl_demo.step);

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}

fn addSdl3(mod: *std.Build.Module) void {
    mod.link_libc = true;
    mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    mod.addRPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    mod.linkSystemLibrary("SDL3", .{});
}
