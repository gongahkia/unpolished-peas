const std = @import("std");
const builtin = @import("builtin");
const supported_zig_version = "0.15.2";

pub fn build(b: *std.Build) void {
    if (!std.mem.eql(u8, builtin.zig_version_string, supported_zig_version)) {
        @panic("unpolished-peas requires Zig " ++ supported_zig_version ++ "; found " ++ builtin.zig_version_string);
    }
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const system_sdl = b.option(bool, "system-sdl", "Link SDL3 from pkg-config instead of the pinned source dependency") orelse false;
    if (b.option([]const u8, "macos-sdk", "macOS SDK path for cross-compilation")) |sdk| b.sysroot = sdk;
    if (!system_sdl and target.result.os.tag == .linux) _ = b.dependency("sdl_linux_deps", .{});
    const bundled_sdl = if (system_sdl) null else b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
    });
    const framework_path = if (target.result.os.tag == .macos) if (b.sysroot) |sysroot| b.pathJoin(&.{ sysroot, "System", "Library", "Frameworks" }) else null else null;
    const box2d = b.dependency("box2d", .{
        .target = target,
        .optimize = optimize,
    });
    const install_assets = b.addInstallDirectory(.{
        .source_dir = b.path("examples/assets"),
        .install_dir = .prefix,
        .install_subdir = "assets",
    });
    b.getInstallStep().dependOn(&install_assets.step);

    const peas = b.addModule("unpolished-peas", .{
        .root_source_file = b.path("src/unpolished_peas.zig"),
        .target = target,
        .optimize = optimize,
    });
    addStb(peas);

    const tools = b.addModule("unpolished-peas-tools", .{
        .root_source_file = b.path("src/tools.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });

    const test_support = b.addModule("unpolished-peas-test", .{
        .root_source_file = b.path("src/test_support.zig"),
        .target = target,
        .optimize = optimize,
    });
    addStb(test_support);

    const services = b.addModule("unpolished-peas-services", .{
        .root_source_file = b.path("src/services.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "unpolished-peas", .module = peas }},
    });

    const sdl = b.addModule("unpolished-peas-sdl3", .{
        .root_source_file = b.path("src/backend/sdl_gpu.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "unpolished-peas", .module = peas },
            .{ .name = "sprite-shaders", .module = b.createModule(.{ .root_source_file = b.path("shaders/embedded.zig") }) },
        },
    });
    addSdl3(sdl, bundled_sdl, framework_path);

    const physics = b.addModule("unpolished-peas-physics", .{
        .root_source_file = b.path("src/physics.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "unpolished-peas", .module = peas }},
    });
    addBox2d(physics, box2d);

    const lib = b.addLibrary(.{
        .name = "unpolished-peas",
        .linkage = .static,
        .root_module = peas,
    });
    b.installArtifact(lib);

    const demo = addExample(b, "unpolished-peas-bounce", "examples/bounce.zig", target, optimize, peas, null);
    const sdl_demo = addExample(b, "unpolished-peas-bounce-sdl", "examples/bounce_sdl.zig", target, optimize, peas, sdl);
    const package_bounce_sdl = b.step("package-bounce-sdl", "Install the bounce SDL sample and assets");
    package_bounce_sdl.dependOn(&b.addInstallArtifact(sdl_demo, .{}).step);
    package_bounce_sdl.dependOn(&install_assets.step);
    const dev_demo = addExample(b, "unpolished-peas-dev-bounce", "examples/dev_bounce.zig", target, optimize, peas, sdl);
    const minimal_demo = addExample(b, "unpolished-peas-minimal", "examples/minimal.zig", target, optimize, peas, sdl);
    const explicit_loop_demo = addExample(b, "unpolished-peas-explicit-loop", "examples/explicit_loop.zig", target, optimize, peas, sdl);
    const audio_demo = addExample(b, "unpolished-peas-audio", "examples/audio.zig", target, optimize, peas, sdl);
    const atlas_demo = addExample(b, "unpolished-peas-atlas", "examples/atlas.zig", target, optimize, peas, sdl);
    const camera_demo = addExample(b, "unpolished-peas-camera", "examples/camera.zig", target, optimize, peas, sdl);
    const tilemap_demo = addExample(b, "unpolished-peas-tilemap", "examples/tilemap.zig", target, optimize, peas, sdl);
    const primitives_demo = addExample(b, "unpolished-peas-primitives", "examples/primitives.zig", target, optimize, peas, sdl);
    const breakout = addExample(b, "unpolished-peas-breakout", "examples/breakout.zig", target, optimize, peas, null);
    const breakout_sdl = addExample(b, "unpolished-peas-breakout-sdl", "examples/breakout_sdl.zig", target, optimize, peas, sdl);
    const topdown_sdl = addExample(b, "unpolished-peas-topdown-sdl", "examples/topdown_sdl.zig", target, optimize, peas, sdl);
    const topdown_scene = addExample(b, "unpolished-peas-test-topdown-scene", "examples/topdown_scene.zig", target, optimize, peas, null);
    const topdown_multiplayer = addExample(b, "unpolished-peas-topdown-multiplayer", "examples/topdown_multiplayer.zig", target, optimize, peas, null);
    const platformer_sdl = b.addExecutable(.{ .name = "unpolished-peas-platformer-sdl", .root_module = b.createModule(.{ .root_source_file = b.path("examples/platformer_sdl.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "unpolished-peas", .module = peas }, .{ .name = "unpolished-peas-sdl3", .module = sdl }, .{ .name = "unpolished-peas-physics", .module = physics } } }) });
    const audio_stress = addExample(b, "unpolished-peas-stress-audio-sdl", "examples/stress_audio_sdl.zig", target, optimize, peas, sdl);
    const packaged_assets = addExample(b, "unpolished-peas-test-packaged-assets", "examples/test_packaged_assets.zig", target, optimize, peas, null);
    const scene_tests = addExample(b, "unpolished-peas-test-scenes", "examples/test_scenes.zig", target, optimize, peas, null);
    const mapc = addExample(b, "upmapc", "src/mapc.zig", target, optimize, peas, null);
    const benchmark = b.addExecutable(.{ .name = "unpolished-peas-benchmark", .root_module = b.createModule(.{ .root_source_file = b.path("src/benchmark.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "unpolished-peas", .module = peas }} }) });

    const peas_cli = b.addExecutable(.{
        .name = "peas",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/peas.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{.{ .name = "unpolished-peas-tools", .module = tools }},
        }),
    });
    const run_peas = b.addRunArtifact(peas_cli);
    run_peas.setEnvironmentVariable("UP_TEMPLATE_ROOT", b.pathFromRoot("templates/bounce"));
    run_peas.setEnvironmentVariable("UP_SCRIPT_ROOT", b.pathFromRoot("script"));
    run_peas.setEnvironmentVariable("UP_REPOSITORY_ROOT", b.pathFromRoot("."));
    if (b.args) |args| run_peas.addArgs(args);
    const peas_step = b.step("peas", "Run the unpolished-peas project CLI");
    peas_step.dependOn(&run_peas.step);
    const peas_tests = b.addTest(.{ .root_module = peas_cli.root_module });
    const run_peas_tests = b.addRunArtifact(peas_tests);
    const peas_test_step = b.step("test-peas", "Run the unpolished-peas project CLI tests");
    peas_test_step.dependOn(&run_peas_tests.step);

    const docs = b.addExecutable(.{
        .name = "unpolished-peas-docs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/docs.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const run_docs = b.addRunArtifact(docs);
    run_docs.addArg(b.pathFromRoot("docs"));
    run_docs.addArg(b.pathFromRoot("src/unpolished_peas.zig"));
    run_docs.addArg(b.pathFromRoot("zig-out/docs"));
    const docs_step = b.step("docs", "Emit validated local Markdown documentation");
    docs_step.dependOn(&run_docs.step);
    const docs_tests = b.addTest(.{ .root_module = docs.root_module });
    const run_docs_tests = b.addRunArtifact(docs_tests);
    const docs_test_step = b.step("test-docs", "Validate local documentation generation and links");
    docs_test_step.dependOn(&run_docs_tests.step);

    const starter = b.addExecutable(.{
        .name = "unpolished-peas-new",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/starter.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{.{ .name = "unpolished-peas-tools", .module = tools }},
        }),
    });
    const run_starter = b.addRunArtifact(starter);
    run_starter.addArg(b.pathFromRoot("templates/bounce"));
    if (b.args) |args| run_starter.addArgs(args);
    const new_step = b.step("new", "Create an unpolished-peas bouncing-square project");
    new_step.dependOn(&run_starter.step);
    const starter_tests = b.addTest(.{ .root_module = starter.root_module });
    const run_starter_tests = b.addRunArtifact(starter_tests);
    const starter_test_step = b.step("test-starter", "Run generated project tests");
    starter_test_step.dependOn(&run_starter_tests.step);

    addRunStep(b, "run-bounce", "Render the bounce demo to zig-out/bounce.ppm", demo);
    addRunStep(b, "run-bounce-sdl", "Run the unpolished-peas SDL3 bounce demo", sdl_demo);
    addRunStep(b, "dev-bounce", "Run the unpolished-peas live-reload demo", dev_demo);
    addRunStep(b, "run-minimal", "Run the unpolished-peas minimal SDL3 demo", minimal_demo);
    addRunStep(b, "run-explicit-loop", "Run the explicit SDL3 loop demo", explicit_loop_demo);
    addRunStep(b, "run-audio", "Run the unpolished-peas audio demo", audio_demo);
    addRunStep(b, "run-atlas", "Run the unpolished-peas atlas sprite demo", atlas_demo);
    addRunStep(b, "run-camera", "Run the unpolished-peas camera demo", camera_demo);
    addRunStep(b, "run-tilemap", "Run the unpolished-peas tile-map demo", tilemap_demo);
    addRunStep(b, "run-primitives", "Run the unpolished-peas GPU primitive demo", primitives_demo);
    addRunStep(b, "run-breakout", "Run the deterministic Breakout demo", breakout);
    addRunStep(b, "run-breakout-sdl", "Run the unpolished-peas SDL3 Breakout demo", breakout_sdl);
    addRunStep(b, "run-topdown-sdl", "Run the unpolished-peas SDL3 top-down demo", topdown_sdl);
    addRunStep(b, "run-topdown-multiplayer", "Run the seeded authoritative top-down multiplayer smoke", topdown_multiplayer);
    addRunStep(b, "test-topdown-scene", "Run the deterministic top-down scene", topdown_scene);
    addRunStep(b, "run-platformer-sdl", "Run the unpolished-peas SDL3 platformer", platformer_sdl);
    const breakout_smoke = b.addRunArtifact(breakout_sdl);
    breakout_smoke.setEnvironmentVariable("UP_ASSET_ROOT", b.pathFromRoot("examples/assets"));
    breakout_smoke.setEnvironmentVariable("SDL_AUDIODRIVER", "dummy");
    breakout_smoke.addArgs(&.{ "--frames", "2" });
    const breakout_smoke_step = b.step("smoke-breakout-sdl", "Run a bounded SDL3 Breakout smoke");
    breakout_smoke_step.dependOn(&breakout_smoke.step);
    const topdown_smoke = b.addRunArtifact(topdown_sdl);
    topdown_smoke.setEnvironmentVariable("UP_ASSET_ROOT", b.pathFromRoot("examples/assets"));
    topdown_smoke.setEnvironmentVariable("SDL_AUDIODRIVER", "dummy");
    topdown_smoke.addArgs(&.{ "--frames", "2" });
    const topdown_smoke_step = b.step("smoke-topdown-sdl", "Run a bounded SDL3 top-down smoke");
    topdown_smoke_step.dependOn(&topdown_smoke.step);
    const platformer_smoke = b.addRunArtifact(platformer_sdl);
    platformer_smoke.setEnvironmentVariable("UP_ASSET_ROOT", b.pathFromRoot("examples/assets"));
    platformer_smoke.setEnvironmentVariable("SDL_AUDIODRIVER", "dummy");
    platformer_smoke.addArgs(&.{ "--frames", "2" });
    const platformer_smoke_step = b.step("smoke-platformer-sdl", "Run a bounded SDL3 platformer smoke");
    platformer_smoke_step.dependOn(&platformer_smoke.step);
    addRunStep(b, "stress-audio-sdl", "Run the local unpolished-peas SDL audio stress smoke", audio_stress);
    addRunStep(b, "test-scenes", "Run deterministic unpolished-peas scene hashes", scene_tests);
    addRunStep(b, "upmapc", "Compile a native .upmap JSON map to .upmapb", mapc);
    addRunStep(b, "benchmark", "Record deterministic engine performance metrics", benchmark);

    const check_examples = b.step("check-examples", "Compile every example without running it");
    for ([_]*std.Build.Step.Compile{ demo, sdl_demo, dev_demo, minimal_demo, explicit_loop_demo, atlas_demo, audio_demo, camera_demo, tilemap_demo, primitives_demo, breakout, breakout_sdl, topdown_sdl, topdown_scene, topdown_multiplayer, platformer_sdl, audio_stress, packaged_assets, scene_tests, mapc, benchmark, peas_cli }) |example| {
        check_examples.dependOn(&example.step);
    }

    const tests = b.addTest(.{ .root_module = peas });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unpolished-peas tests");
    test_step.dependOn(&run_tests.step);
    const tools_tests = b.addTest(.{ .root_module = tools });
    const run_tools_tests = b.addRunArtifact(tools_tests);
    const test_support_tests = b.addTest(.{ .root_module = test_support });
    const run_test_support_tests = b.addRunArtifact(test_support_tests);
    const test_support_step = b.step("test-support", "Run deterministic test fixture support tests");
    test_support_step.dependOn(&run_test_support_tests.step);
    const services_tests = b.addTest(.{ .root_module = services });
    const run_services_tests = b.addRunArtifact(services_tests);
    const module_test_step = b.step("test-modules", "Compile and test independent core, tools, test fixtures, and services modules");
    module_test_step.dependOn(&run_tests.step);
    module_test_step.dependOn(&run_tools_tests.step);
    module_test_step.dependOn(&run_test_support_tests.step);
    module_test_step.dependOn(&run_services_tests.step);
    const fuzz_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/fuzz_targets.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    addStb(fuzz_tests.root_module);
    const run_fuzz_tests = b.addRunArtifact(fuzz_tests);
    const fuzz_test_step = b.step("test-fuzz", "Run bounded decoder and protocol fuzz corpus");
    fuzz_test_step.dependOn(&run_fuzz_tests.step);

    const breakout_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("examples/breakout_game.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "unpolished-peas", .module = peas }},
    }) });
    const run_breakout_tests = b.addRunArtifact(breakout_tests);
    const breakout_test_step = b.step("test-breakout", "Run deterministic Breakout tests");
    breakout_test_step.dependOn(&run_breakout_tests.step);
    const topdown_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("examples/topdown_game.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "unpolished-peas", .module = peas }},
    }) });
    const run_topdown_tests = b.addRunArtifact(topdown_tests);
    const topdown_test_step = b.step("test-topdown", "Run deterministic top-down tests");
    topdown_test_step.dependOn(&run_topdown_tests.step);
    const topdown_multiplayer_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("examples/topdown_multiplayer.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "unpolished-peas", .module = peas }},
    }) });
    const run_topdown_multiplayer_tests = b.addRunArtifact(topdown_multiplayer_tests);
    const topdown_multiplayer_test_step = b.step("test-topdown-multiplayer", "Run seeded authoritative top-down multiplayer tests");
    topdown_multiplayer_test_step.dependOn(&run_topdown_multiplayer_tests.step);
    const platformer_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("examples/platformer_game.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "unpolished-peas", .module = peas }},
    }) });
    const run_platformer_tests = b.addRunArtifact(platformer_tests);
    const platformer_test_step = b.step("test-platformer", "Run deterministic platformer fixtures");
    platformer_test_step.dependOn(&run_platformer_tests.step);
    const replay_test_step = b.step("test-replays", "Run stored fixed-step input replays");
    replay_test_step.dependOn(&run_breakout_tests.step);
    replay_test_step.dependOn(&run_topdown_tests.step);
    replay_test_step.dependOn(&run_platformer_tests.step);

    const sdl_tests = b.addTest(.{ .root_module = sdl });
    const run_sdl_tests = b.addRunArtifact(sdl_tests);
    const sdl_test_step = b.step("test-sdl", "Compile the SDL3 runtime against its configured dependency");
    sdl_test_step.dependOn(&run_sdl_tests.step);
    const renderer_conformance = b.addRunArtifact(sdl_tests);
    renderer_conformance.setEnvironmentVariable("UP_RENDERER_CONFORMANCE", "1");
    const renderer_conformance_step = b.step("test-renderer-conformance", "Run shared desktop renderer smoke and GPU golden fixtures");
    renderer_conformance_step.dependOn(&renderer_conformance.step);

    const box2d_tests = b.addTest(.{ .root_module = physics });
    const run_box2d_tests = b.addRunArtifact(box2d_tests);
    const box2d_test_step = b.step("test-box2d", "Compile the pinned Box2D source dependency");
    box2d_test_step.dependOn(&run_box2d_tests.step);
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
    run.setEnvironmentVariable("UP_ASSET_ROOT", b.pathFromRoot("examples/assets"));
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
        .file = mod.owner.path("src/vendor/stb_truetype.c"),
        .flags = &.{"-std=c99"},
    });
    mod.addCSourceFile(.{
        .file = mod.owner.path("vendor/stb/stb_vorbis.c"),
        .flags = &.{ "-std=c99", "-DSTB_VORBIS_NO_STDIO" },
    });
}

fn addSdl3(mod: *std.Build.Module, bundled_sdl: ?*std.Build.Dependency, framework_path: ?[]const u8) void {
    mod.link_libc = true;
    if (framework_path) |path| mod.addSystemFrameworkPath(.{ .cwd_relative = path });
    if (bundled_sdl) |dependency| {
        mod.addIncludePath(dependency.path("include"));
        mod.linkLibrary(dependency.artifact("SDL3"));
    } else {
        mod.linkSystemLibrary("sdl3", .{ .use_pkg_config = .force });
    }
}

fn addBox2d(mod: *std.Build.Module, dependency: *std.Build.Dependency) void {
    mod.link_libc = true;
    mod.addIncludePath(dependency.path("include"));
    mod.linkLibrary(dependency.artifact("box2d"));
}
