const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const peas = b.addModule("unpolished-peas", .{
        .root_source_file = b.path("src/unpolished_peas.zig"),
        .target = target,
        .optimize = optimize,
    });
    addStb(peas);

    const sdl = b.addModule("unpolished-peas-sdl3", .{
        .root_source_file = b.path("src/backend/sdl_gpu.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "unpolished-peas", .module = peas },
        },
    });
    addSdl3(sdl);

    const lib = b.addLibrary(.{
        .name = "unpolished-peas",
        .linkage = .static,
        .root_module = peas,
    });
    b.installArtifact(lib);

    const demo = addExample(b, "unpolished-peas-bounce", "examples/bounce.zig", target, optimize, peas, null);
    const sdl_demo = addExample(b, "unpolished-peas-bounce-sdl", "examples/bounce_sdl.zig", target, optimize, peas, sdl);
    const dev_demo = addExample(b, "unpolished-peas-dev-bounce", "examples/dev_bounce.zig", target, optimize, peas, sdl);
    const minimal_demo = addExample(b, "unpolished-peas-minimal", "examples/minimal.zig", target, optimize, peas, sdl);
    const audio_demo = addExample(b, "unpolished-peas-audio", "examples/audio.zig", target, optimize, peas, sdl);
    const atlas_demo = addExample(b, "unpolished-peas-atlas", "examples/atlas.zig", target, optimize, peas, sdl);
    const audio_stress = addExample(b, "unpolished-peas-stress-audio-sdl", "examples/stress_audio_sdl.zig", target, optimize, peas, sdl);
    const scene_tests = addExample(b, "unpolished-peas-test-scenes", "examples/test_scenes.zig", target, optimize, peas, null);

    const starter = b.addExecutable(.{
        .name = "unpolished-peas-new",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/starter.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const run_starter = b.addRunArtifact(starter);
    run_starter.addArg(b.pathFromRoot("."));
    run_starter.addArg(b.pathFromRoot("templates/bounce"));
    if (b.args) |args| run_starter.addArgs(args);
    const new_step = b.step("new", "Create an unpolished-peas bouncing-square project");
    new_step.dependOn(&run_starter.step);

    addRunStep(b, "run-bounce", "Render the bounce demo to zig-out/bounce.ppm", demo);
    addRunStep(b, "run-bounce-sdl", "Run the unpolished-peas SDL3 bounce demo", sdl_demo);
    addRunStep(b, "dev-bounce", "Run the unpolished-peas live-reload demo", dev_demo);
    addRunStep(b, "run-minimal", "Run the unpolished-peas minimal SDL3 demo", minimal_demo);
    addRunStep(b, "run-audio", "Run the unpolished-peas audio demo", audio_demo);
    addRunStep(b, "run-atlas", "Run the unpolished-peas atlas sprite demo", atlas_demo);
    addRunStep(b, "stress-audio-sdl", "Run the local unpolished-peas SDL audio stress smoke", audio_stress);
    addRunStep(b, "test-scenes", "Run deterministic unpolished-peas scene hashes", scene_tests);

    const tests = b.addTest(.{ .root_module = peas });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unpolished-peas tests");
    test_step.dependOn(&run_tests.step);
}

fn addExample(
    b: *std.Build,
    name: []const u8,
    path: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    peas: *std.Build.Module,
    sdl: ?*std.Build.Module,
) *std.Build.Step.Compile {
    var imports = std.ArrayList(std.Build.Module.Import).empty;
    imports.append(b.allocator, .{ .name = "unpolished-peas", .module = peas }) catch @panic("OOM");
    if (sdl) |module| imports.append(b.allocator, .{ .name = "unpolished-peas-sdl3", .module = module }) catch @panic("OOM");
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            .imports = imports.items,
        }),
    });
    b.installArtifact(exe);
    return exe;
}

fn addRunStep(b: *std.Build, name: []const u8, description: []const u8, exe: *std.Build.Step.Compile) void {
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    const step = b.step(name, description);
    step.dependOn(&run.step);
}

fn addStb(mod: *std.Build.Module) void {
    mod.link_libc = true;
    mod.addIncludePath(mod.owner.path("vendor/stb"));
    mod.addCSourceFile(.{
        .file = mod.owner.path("src/vendor/stb_image.c"),
        .flags = &.{"-std=c99"},
    });
    mod.addCSourceFile(.{
        .file = mod.owner.path("vendor/stb/stb_vorbis.c"),
        .flags = &.{ "-std=c99", "-DSTB_VORBIS_NO_STDIO" },
    });
}

fn addSdl3(mod: *std.Build.Module) void {
    mod.link_libc = true;
    mod.linkSystemLibrary("sdl3", .{ .use_pkg_config = .force });
}
