const std = @import("std");
const builtin = @import("builtin");
const current_zig_version = "0.15.2";
const previous_zig_version = "0.15.1";

pub fn build(b: *std.Build) void {
    if (!std.mem.eql(u8, builtin.zig_version_string, current_zig_version) and !std.mem.eql(u8, builtin.zig_version_string, previous_zig_version)) {
        @panic("unpolished-peas requires Zig " ++ previous_zig_version ++ " or " ++ current_zig_version ++ "; found " ++ builtin.zig_version_string);
    }
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const browser_optimize = b.option(std.builtin.OptimizeMode, "browser-optimize", "Optimization mode for the standalone browser Wasm runtime") orelse .ReleaseSmall;
    const browser_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const wasi_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi });
    const system_sdl = b.option(bool, "system-sdl", "Link SDL3 from pkg-config instead of the pinned source dependency") orelse false;
    const with_sdl = b.option(bool, "with_sdl", "Resolve the SDL3 runtime") orelse true;
    if (b.option([]const u8, "macos-sdk", "macOS SDK path for cross-compilation")) |sdk| b.sysroot = sdk;
    if (with_sdl and !system_sdl and target.result.os.tag == .linux) _ = b.lazyDependency("sdl_linux_deps", .{});
    const bundled_sdl = if (!with_sdl or system_sdl) null else b.lazyDependency("sdl", .{
        .target = target,
        .optimize = optimize,
    });
    const framework_path = if (target.result.os.tag == .macos) if (b.sysroot) |sysroot| b.pathJoin(&.{ sysroot, "System", "Library", "Frameworks" }) else null else null;
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
    if (target.result.cpu.arch != .wasm32) addStb(peas);
    const wasm_peas = b.addModule("unpolished-peas-wasm-core", .{
        .root_source_file = b.path("src/unpolished_peas.zig"),
        .target = wasi_target,
        .optimize = browser_optimize,
    });
    const browser_peas = b.addModule("unpolished-peas-browser-core", .{
        .root_source_file = b.path("src/unpolished_peas.zig"),
        .target = browser_target,
        .optimize = browser_optimize,
    });

    const tools = b.addModule("unpolished-peas-tools", .{
        .root_source_file = b.path("src/tools.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const public_import_inventory = b.addExecutable(.{
        .name = "public-import-inventory",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/public_import_inventory.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const run_public_import_inventory = b.addRunArtifact(public_import_inventory);
    run_public_import_inventory.addArgs(&.{ b.pathFromRoot("."), b.pathFromRoot("fixtures/public_import_inventory.json") });
    const public_import_inventory_step = b.step("public-import-inventory", "Print public imports used by examples, fixtures, and templates");
    public_import_inventory_step.dependOn(&run_public_import_inventory.step);
    const check_public_import_inventory = b.addRunArtifact(public_import_inventory);
    check_public_import_inventory.addArgs(&.{ b.pathFromRoot("."), b.pathFromRoot("fixtures/public_import_inventory.json"), "--check" });
    const check_public_import_inventory_step = b.step("check-public-import-inventory", "Verify the public import inventory");
    check_public_import_inventory_step.dependOn(&check_public_import_inventory.step);

    const test_support = b.addModule("unpolished-peas-test", .{
        .root_source_file = b.path("src/test_support.zig"),
        .target = target,
        .optimize = optimize,
    });
    addStb(test_support);

    const browser_protocol_game = b.createModule(.{
        .root_source_file = b.path("fixtures/protocol-desktop/src/protocol_game.zig"),
        .target = browser_target,
        .optimize = browser_optimize,
        .imports = &.{.{ .name = "unpolished-peas", .module = browser_peas }},
    });
    const browser_runtime = b.addExecutable(.{
        .name = "unpolished-peas",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/browser/runtime.zig"),
            .target = browser_target,
            .optimize = browser_optimize,
            .imports = &.{
                .{ .name = "unpolished-peas", .module = browser_peas },
                .{ .name = "protocol-game", .module = browser_protocol_game },
            },
        }),
    });
    browser_runtime.entry = .disabled;
    browser_runtime.rdynamic = true;
    browser_runtime.import_memory = true;
    const browser_protocol_runtime = b.addExecutable(.{
        .name = "unpolished-peas-protocol",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/browser/protocol_runtime.zig"),
            .target = browser_target,
            .optimize = browser_optimize,
            .imports = &.{
                .{ .name = "unpolished-peas", .module = browser_peas },
                .{ .name = "protocol-game", .module = browser_protocol_game },
            },
        }),
    });
    browser_protocol_runtime.entry = .disabled;
    browser_protocol_runtime.rdynamic = true;
    browser_protocol_runtime.import_memory = true;
    const install_browser_protocol_runtime = b.addInstallArtifact(browser_protocol_runtime, .{
        .dest_dir = .{ .override = .{ .custom = "web" } },
        .dest_sub_path = "unpolished-peas-protocol.wasm",
    });
    const browser_protocol_step = b.step("browser-protocol", "Build the browser stable-protocol fixture");
    browser_protocol_step.dependOn(&install_browser_protocol_runtime.step);
    const browser_protocol_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/browser/protocol_runtime.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "unpolished-peas", .module = peas },
            .{ .name = "protocol-game", .module = b.createModule(.{
                .root_source_file = b.path("fixtures/protocol-desktop/src/protocol_game.zig"),
                .target = b.graph.host,
                .optimize = optimize,
                .imports = &.{.{ .name = "unpolished-peas", .module = peas }},
            }) },
        },
    }) });
    const run_browser_protocol_tests = b.addRunArtifact(browser_protocol_tests);
    const browser_protocol_test_step = b.step("test-browser-protocol", "Test the browser stable-protocol fixture");
    browser_protocol_test_step.dependOn(&run_browser_protocol_tests.step);
    const browser_protocol_host_test = b.addSystemCommand(&.{ "node", "script/test_browser_protocol_host.mjs" });
    browser_protocol_host_test.setCwd(b.path("."));
    browser_protocol_host_test.step.dependOn(&install_browser_protocol_runtime.step);
    const browser_protocol_host_test_step = b.step("test-browser-protocol-host", "Instantiate the browser stable-protocol fixture against the host ABI");
    browser_protocol_host_test_step.dependOn(&browser_protocol_host_test.step);
    const install_browser_runtime = b.addInstallArtifact(browser_runtime, .{
        .dest_dir = .{ .override = .{ .custom = "web" } },
        .dest_sub_path = "unpolished-peas.wasm",
    });
    const browser_step = b.step("browser", "Build the wasm32-freestanding browser runtime in zig-out/web");
    browser_step.dependOn(&install_browser_runtime.step);
    const host_protocol_game = b.createModule(.{
        .root_source_file = b.path("fixtures/protocol-desktop/src/protocol_game.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{.{ .name = "unpolished-peas", .module = peas }},
    });
    const browser_runtime_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/browser/runtime.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "unpolished-peas", .module = peas },
            .{ .name = "protocol-game", .module = host_protocol_game },
        },
    }) });
    const run_browser_runtime_tests = b.addRunArtifact(browser_runtime_tests);
    const browser_runtime_test_step = b.step("test-browser-runtime", "Test the host-independent browser runtime boundary");
    browser_runtime_test_step.dependOn(&run_browser_runtime_tests.step);
    const browser_contract_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/browser/contract.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    }) });
    const run_browser_contract_tests = b.addRunArtifact(browser_contract_tests);
    const browser_contract_test_step = b.step("test-browser-contract", "Test the versioned browser host contract");
    browser_contract_test_step.dependOn(&run_browser_contract_tests.step);
    const browser_scaffold_test = b.addSystemCommand(&.{"script/test_browser_scaffold.sh"});
    browser_scaffold_test.setCwd(b.path("."));
    const browser_scaffold_test_step = b.step("test-browser-scaffold", "Validate browser Wasm artifact layout");
    browser_scaffold_test_step.dependOn(&browser_scaffold_test.step);
    const browser_host_test = b.addSystemCommand(&.{ "node", "script/test_browser_host.mjs" });
    browser_host_test.setCwd(b.path("."));
    const browser_host_test_step = b.step("test-browser-host", "Test browser WebGL 2 host bindings");
    browser_host_test_step.dependOn(&browser_host_test.step);
    const browser_input_test = b.addSystemCommand(&.{ "node", "script/test_browser_input.mjs" });
    browser_input_test.setCwd(b.path("."));
    const browser_input_test_step = b.step("test-browser-input", "Test browser DOM input bindings");
    browser_input_test_step.dependOn(&browser_input_test.step);
    const browser_audio_test = b.addSystemCommand(&.{ "node", "script/test_browser_audio.mjs" });
    browser_audio_test.setCwd(b.path("."));
    const browser_audio_test_step = b.step("test-browser-audio", "Test browser audio bindings");
    browser_audio_test_step.dependOn(&browser_audio_test.step);
    const browser_storage_test = b.addSystemCommand(&.{ "node", "script/test_browser_storage.mjs" });
    browser_storage_test.setCwd(b.path("."));
    const browser_storage_test_step = b.step("test-browser-storage", "Test browser persistence bindings");
    browser_storage_test_step.dependOn(&browser_storage_test.step);
    const browser_artifacts_test = b.addSystemCommand(&.{ "node", "script/test_browser_artifacts.mjs" });
    browser_artifacts_test.setCwd(b.path("."));
    const browser_artifacts_test_step = b.step("test-browser-artifacts", "Test browser diagnostics artifacts");
    browser_artifacts_test_step.dependOn(&browser_artifacts_test.step);
    const web_package_test = b.addSystemCommand(&.{"script/test_web_package.sh"});
    web_package_test.setCwd(b.path("."));
    const web_package_test_step = b.step("test-web-package", "Validate deterministic browser package layout");
    web_package_test_step.dependOn(&web_package_test.step);
    const browser_chromium_test = b.addSystemCommand(&.{"script/test_browser_chromium.sh"});
    browser_chromium_test.setCwd(b.path("."));
    const browser_chromium_test_step = b.step("test-browser-chromium", "Run Chromium against the browser bundle");
    browser_chromium_test_step.dependOn(&browser_chromium_test.step);
    const web_proof_game_matrix = b.addSystemCommand(&.{"script/test_web_proof_game_matrix.sh"});
    web_proof_game_matrix.setCwd(b.path("."));
    const web_proof_game_matrix_step = b.step("test-web-proof-game-matrix", "Package and smoke every proof game in Chromium");
    web_proof_game_matrix_step.dependOn(&web_proof_game_matrix.step);
    const browser_wasm_host_test = b.addSystemCommand(&.{ "node", "script/test_browser_wasm_host.mjs" });
    browser_wasm_host_test.setCwd(b.path("."));
    browser_wasm_host_test.step.dependOn(&install_browser_runtime.step);
    const browser_wasm_host_test_step = b.step("test-browser-wasm-host", "Instantiate the browser Wasm module against its host ABI");
    browser_wasm_host_test_step.dependOn(&browser_wasm_host_test.step);

    const sdl = b.addModule("unpolished-peas-sdl3", .{
        .root_source_file = b.path("src/backend/sdl_gpu.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "unpolished-peas", .module = peas },
            .{ .name = "sprite-shaders", .module = b.createModule(.{ .root_source_file = b.path("shaders/embedded.zig") }) },
        },
    });
    if (with_sdl and (system_sdl or bundled_sdl != null)) addSdl3(sdl, bundled_sdl, framework_path);

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
    const explicit_loop_demo = addExample(b, "unpolished-peas-explicit-loop", "examples/explicit_loop.zig", target, optimize, peas, null);
    const explicit_loop_wasm = b.addExecutable(.{ .name = "unpolished-peas-explicit-loop-wasm", .root_module = b.createModule(.{
        .root_source_file = b.path("examples/explicit_loop.zig"),
        .target = wasi_target,
        .optimize = browser_optimize,
        .imports = &.{.{ .name = "unpolished-peas", .module = wasm_peas }},
    }) });
    explicit_loop_wasm.entry = .disabled;
    explicit_loop_wasm.rdynamic = true;
    explicit_loop_wasm.import_memory = true;
    const audio_demo = addExample(b, "unpolished-peas-audio", "examples/audio.zig", target, optimize, peas, sdl);
    const atlas_demo = addExample(b, "unpolished-peas-atlas", "examples/atlas.zig", target, optimize, peas, sdl);
    const camera_demo = addExample(b, "unpolished-peas-camera", "examples/camera.zig", target, optimize, peas, sdl);
    const primitives_demo = addExample(b, "unpolished-peas-primitives", "examples/primitives.zig", target, optimize, peas, sdl);
    const breakout = addExample(b, "unpolished-peas-breakout", "examples/breakout.zig", target, optimize, peas, null);
    const breakout_sdl = addExample(b, "unpolished-peas-breakout-sdl", "examples/breakout_sdl.zig", target, optimize, peas, sdl);
    const topdown_sdl = addExample(b, "unpolished-peas-topdown-sdl", "examples/topdown_sdl.zig", target, optimize, peas, sdl);
    const package_topdown_sdl = b.step("package-topdown-sdl", "Install the top-down SDL sample and assets");
    package_topdown_sdl.dependOn(&b.addInstallArtifact(topdown_sdl, .{}).step);
    package_topdown_sdl.dependOn(&install_assets.step);
    const audio_stress = addExample(b, "unpolished-peas-stress-audio-sdl", "examples/stress_audio_sdl.zig", target, optimize, peas, sdl);
    const packaged_assets = addExample(b, "unpolished-peas-test-packaged-assets", "examples/test_packaged_assets.zig", target, optimize, peas, null);
    const packaged_layout = addExample(b, "unpolished-peas-test-packaged-layout", "examples/test_packaged_layout.zig", target, optimize, peas, sdl);
    const install_packaged_layout = b.addInstallArtifact(packaged_layout, .{});
    const packaged_layout_step = b.step("package-layout-checker", "Install the portable package layout checker");
    packaged_layout_step.dependOn(&install_packaged_layout.step);
    const scene_tests = addExample(b, "unpolished-peas-test-scenes", "examples/test_scenes.zig", target, optimize, peas, null);
    const proof_benchmark = addExample(b, "unpolished-peas-proof-benchmark", "examples/proof_benchmark.zig", target, optimize, peas, null);
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
    const starter_template_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("templates/bounce/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "unpolished-peas", .module = peas },
            .{ .name = "unpolished-peas-sdl3", .module = sdl },
        },
    }) });
    const run_starter_template_tests = b.addRunArtifact(starter_template_tests);
    const starter_template_test_step = b.step("test-starter-template", "Compile the starter against the local core API");
    starter_template_test_step.dependOn(&run_starter_template_tests.step);
    starter_test_step.dependOn(&run_starter_template_tests.step);

    addRunStep(b, "run-bounce", "Render the bounce demo to zig-out/bounce.ppm", demo);
    addRunStep(b, "run-bounce-sdl", "Run the unpolished-peas SDL3 bounce demo", sdl_demo);
    addRunStep(b, "dev-bounce", "Run the unpolished-peas live-reload demo", dev_demo);
    addRunStep(b, "run-minimal", "Run the unpolished-peas minimal SDL3 demo", minimal_demo);
    addRunStep(b, "run-explicit-loop", "Run the advanced core explicit-loop example", explicit_loop_demo);
    addRunStep(b, "run-audio", "Run the unpolished-peas audio demo", audio_demo);
    addRunStep(b, "run-atlas", "Run the unpolished-peas atlas sprite demo", atlas_demo);
    addRunStep(b, "run-camera", "Run the unpolished-peas camera demo", camera_demo);
    addRunStep(b, "run-primitives", "Run the unpolished-peas GPU primitive demo", primitives_demo);
    addRunStep(b, "run-breakout", "Run the deterministic Breakout demo", breakout);
    addRunStep(b, "run-breakout-sdl", "Run the unpolished-peas SDL3 Breakout demo", breakout_sdl);
    addRunStep(b, "run-topdown-sdl", "Run the unpolished-peas SDL3 top-down demo", topdown_sdl);
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
    const desktop_package_matrix = b.addSystemCommand(&.{ "script/test_desktop_package_matrix.sh", @tagName(target.result.os.tag) });
    desktop_package_matrix.setCwd(b.path("."));
    const desktop_package_matrix_step = b.step("test-desktop-package-matrix", "Package and smoke every proof game for the host desktop platform");
    desktop_package_matrix_step.dependOn(&desktop_package_matrix.step);
    const cross_target_integrity = b.addSystemCommand(&.{"script/test_cross_target_integrity.sh"});
    cross_target_integrity.setCwd(b.path("."));
    const cross_target_integrity_step = b.step("test-cross-target-integrity", "Verify desktop and Chromium diagnostics and package integrity");
    cross_target_integrity_step.dependOn(&cross_target_integrity.step);
    addRunStep(b, "stress-audio-sdl", "Run the local unpolished-peas SDL audio stress smoke", audio_stress);
    addRunStep(b, "test-scenes", "Run deterministic unpolished-peas scene hashes", scene_tests);
    addRunStep(b, "benchmark", "Record deterministic engine performance metrics", benchmark);
    addRunStep(b, "benchmark-proofs", "Record deterministic proof-game performance metrics", proof_benchmark);

    const check_examples = b.step("check-examples", "Compile every example without running it");
    for ([_]*std.Build.Step.Compile{ demo, sdl_demo, dev_demo, minimal_demo, explicit_loop_demo, explicit_loop_wasm, atlas_demo, audio_demo, camera_demo, primitives_demo, breakout, breakout_sdl, topdown_sdl, audio_stress, packaged_assets, packaged_layout, scene_tests, proof_benchmark, benchmark, peas_cli }) |example| {
        check_examples.dependOn(&example.step);
    }
    const explicit_loop_wasm_step = b.step("test-explicit-loop-wasm", "Compile the advanced explicit-loop example for Wasm");
    explicit_loop_wasm_step.dependOn(&explicit_loop_wasm.step);

    const tests = b.addTest(.{ .root_module = peas });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unpolished-peas tests");
    test_step.dependOn(&run_tests.step);
    const core_api_snapshot_module = b.createModule(.{
        .root_source_file = b.path("src/core_api_snapshot.zig"),
        .target = target,
        .optimize = optimize,
    });
    addStb(core_api_snapshot_module);
    const core_api_snapshot_tests = b.addTest(.{ .root_module = core_api_snapshot_module });
    const run_core_api_snapshot_tests = b.addRunArtifact(core_api_snapshot_tests);
    const core_api_snapshot_test_step = b.step("test-core-api", "Verify the frozen core API snapshot");
    core_api_snapshot_test_step.dependOn(&run_core_api_snapshot_tests.step);
    test_step.dependOn(&run_core_api_snapshot_tests.step);
    const core_downstream_fixture = b.addSystemCommand(&.{"script/test_core_downstream_fixture.sh"});
    core_downstream_fixture.setCwd(b.path("."));
    const core_downstream_fixture_test_step = b.step("test-core-downstream", "Build the external frozen-core fixture");
    core_downstream_fixture_test_step.dependOn(&core_downstream_fixture.step);
    const dependency_ceiling = b.addSystemCommand(&.{ "python3", "script/check_core_dependency_ceiling.py" });
    dependency_ceiling.setCwd(b.path("."));
    dependency_ceiling.setEnvironmentVariable("PYTHONDONTWRITEBYTECODE", "1");
    const dependency_ceiling_tests = b.addSystemCommand(&.{ "python3", "script/test_check_core_dependency_ceiling.py" });
    dependency_ceiling_tests.setCwd(b.path("."));
    dependency_ceiling_tests.setEnvironmentVariable("PYTHONDONTWRITEBYTECODE", "1");
    const dependency_ceiling_test_step = b.step("test-dependency-ceiling", "Enforce the v0.1 core dependency ceiling");
    dependency_ceiling_test_step.dependOn(&dependency_ceiling.step);
    dependency_ceiling_test_step.dependOn(&dependency_ceiling_tests.step);
    test_step.dependOn(&dependency_ceiling.step);
    const facade_consumer_matrix = b.addSystemCommand(&.{"script/test_facade_consumer_matrix.sh"});
    facade_consumer_matrix.setCwd(b.path("."));
    const facade_consumer_matrix_step = b.step("test-facade-consumer-matrix", "Build independent desktop and Wasm facade consumers");
    facade_consumer_matrix_step.dependOn(&facade_consumer_matrix.step);
    const protocol_desktop_fixture = b.addSystemCommand(&.{"script/test_protocol_desktop_fixture.sh"});
    protocol_desktop_fixture.setCwd(b.path("."));
    const protocol_desktop_fixture_test_step = b.step("test-protocol-desktop", "Build and run the stable-protocol desktop fixture");
    protocol_desktop_fixture_test_step.dependOn(&protocol_desktop_fixture.step);
    const public_import_inventory_tests = b.addTest(.{ .root_module = public_import_inventory.root_module });
    const run_public_import_inventory_tests = b.addRunArtifact(public_import_inventory_tests);
    const public_import_inventory_test_step = b.step("test-public-import-inventory", "Test public import inventory generation");
    public_import_inventory_test_step.dependOn(&run_public_import_inventory_tests.step);
    public_import_inventory_test_step.dependOn(&check_public_import_inventory.step);
    test_step.dependOn(&run_public_import_inventory_tests.step);
    test_step.dependOn(&check_public_import_inventory.step);
    const tools_tests = b.addTest(.{ .root_module = tools });
    const run_tools_tests = b.addRunArtifact(tools_tests);
    const test_support_tests = b.addTest(.{ .root_module = test_support });
    const run_test_support_tests = b.addRunArtifact(test_support_tests);
    const test_support_step = b.step("test-support", "Run deterministic test fixture support tests");
    test_support_step.dependOn(&run_test_support_tests.step);
    const module_test_step = b.step("test-modules", "Compile and test independent core, tools, and test-fixture modules");
    module_test_step.dependOn(&run_tests.step);
    module_test_step.dependOn(&run_tools_tests.step);
    module_test_step.dependOn(&run_test_support_tests.step);
    const release_gate = b.addSystemCommand(&.{"script/release_gate.sh"});
    release_gate.setCwd(b.path("."));
    const release_gate_step = b.step("release-gate", "Run the v1 release validation gate");
    release_gate_step.dependOn(&release_gate.step);
    const release_candidate_clean_consumer = b.addSystemCommand(&.{"script/test_release_candidate_clean_consumer.sh"});
    release_candidate_clean_consumer.setCwd(b.path("."));
    const release_candidate_clean_consumer_step = b.step("test-release-candidate-clean-consumer", "Validate a clean released dependency consumer");
    release_candidate_clean_consumer_step.dependOn(&release_candidate_clean_consumer.step);

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
    const replay_test_step = b.step("test-replays", "Run stored fixed-step input replays");
    replay_test_step.dependOn(&run_breakout_tests.step);
    replay_test_step.dependOn(&run_topdown_tests.step);

    const sdl_tests = b.addTest(.{ .root_module = sdl });
    const run_sdl_tests = b.addRunArtifact(sdl_tests);
    const sdl_test_step = b.step("test-sdl", "Compile the SDL3 runtime against its configured dependency");
    sdl_test_step.dependOn(&run_sdl_tests.step);
    const renderer_conformance = b.addRunArtifact(sdl_tests);
    renderer_conformance.setEnvironmentVariable("UP_RENDERER_CONFORMANCE", "1");
    const renderer_conformance_step = b.step("test-renderer-conformance", "Run shared desktop renderer smoke and GPU golden fixtures");
    renderer_conformance_step.dependOn(&renderer_conformance.step);
    const opengl_conformance = b.addRunArtifact(sdl_tests);
    opengl_conformance.setEnvironmentVariable("UP_OPENGL_CONFORMANCE", "1");
    const opengl_conformance_step = b.step("test-opengl", "Run the OpenGL 3.3 desktop presenter conformance fixture");
    opengl_conformance_step.dependOn(&opengl_conformance.step);
    const cross_backend_conformance = b.addRunArtifact(sdl_tests);
    cross_backend_conformance.setEnvironmentVariable("UP_CROSS_BACKEND_CONFORMANCE", "1");
    const cross_backend_conformance_step = b.step("test-renderer-cross-backend", "Compare SDL GPU and OpenGL renderer captures");
    cross_backend_conformance_step.dependOn(&cross_backend_conformance.step);
    const three_backend_renderer = b.addSystemCommand(&.{"script/test_renderer_three_backend.sh"});
    three_backend_renderer.setCwd(b.path("."));
    const three_backend_renderer_step = b.step("test-renderer-three-backend", "Compare SDL GPU, OpenGL, and WebGL 2 renderer captures");
    three_backend_renderer_step.dependOn(&three_backend_renderer.step);
    const desktop_backend_comparison = b.addSystemCommand(&.{"script/check_desktop_backend_comparison.sh"});
    desktop_backend_comparison.setCwd(b.path("."));
    const desktop_backend_comparison_step = b.step("test-desktop-backends", "Compare desktop renderer replays and captures");
    desktop_backend_comparison_step.dependOn(&desktop_backend_comparison.step);
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
