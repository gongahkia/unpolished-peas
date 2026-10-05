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
    addBrowserStb(wasm_peas);
    addBrowserVorbis(wasm_peas);
    const browser_peas = b.addModule("unpolished-peas-browser-core", .{
        .root_source_file = b.path("src/unpolished_peas.zig"),
        .target = browser_target,
        .optimize = browser_optimize,
    });
    addBrowserStb(browser_peas);
    addBrowserVorbis(browser_peas);
    const frame_timing = b.createModule(.{
        .root_source_file = b.path("src/frame_timing.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "unpolished-peas", .module = peas }},
    });
    const browser_frame_timing = b.createModule(.{
        .root_source_file = b.path("src/frame_timing.zig"),
        .target = browser_target,
        .optimize = browser_optimize,
        .imports = &.{.{ .name = "unpolished-peas", .module = browser_peas }},
    });
    // This module is the supported browser build boundary. A consuming build
    // supplies its game as the `protocol-game` import; it never needs a Peas
    // checkout or a private browser runtime path.
    _ = b.addModule("unpolished-peas-browser-runtime", .{
        .root_source_file = b.path("src/browser/runtime.zig"),
        .target = browser_target,
        .optimize = browser_optimize,
        .imports = &.{
            .{ .name = "unpolished-peas", .module = browser_peas },
            .{ .name = "frame-timing", .module = browser_frame_timing },
        },
    });
    const workload_catalog = b.createModule(.{
        .root_source_file = b.path("src/workload_catalog.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "unpolished-peas", .module = peas },
            .{ .name = "workload-catalog-data", .module = b.createModule(.{
                .root_source_file = b.path("benchmarks/workloads/catalog_data.zig"),
                .target = target,
                .optimize = optimize,
            }) },
        },
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
    const browser_starter_game = b.createModule(.{
        .root_source_file = b.path("templates/starter/src/game.zig"),
        .target = browser_target,
        .optimize = browser_optimize,
        .imports = &.{.{ .name = "unpolished-peas", .module = browser_peas }},
    });
    const browser_dogfood_game = b.createModule(.{
        .root_source_file = b.path("dogfood/neon-siege/src/game.zig"),
        .target = browser_target,
        .optimize = browser_optimize,
        .imports = &.{
            .{ .name = "unpolished-peas", .module = browser_peas },
            .{ .name = "neon-siege-assets", .module = b.createModule(.{ .root_source_file = b.path("dogfood/neon-siege/embedded_assets.zig"), .target = browser_target, .optimize = browser_optimize }) },
        },
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
                .{ .name = "frame-timing", .module = browser_frame_timing },
            },
        }),
    });
    browser_runtime.entry = .disabled;
    browser_runtime.rdynamic = true;
    browser_runtime.import_memory = true;
    const browser_starter_runtime = b.addExecutable(.{
        .name = "unpolished-peas-starter",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/browser/runtime.zig"),
            .target = browser_target,
            .optimize = browser_optimize,
            .imports = &.{
                .{ .name = "unpolished-peas", .module = browser_peas },
                .{ .name = "protocol-game", .module = browser_starter_game },
                .{ .name = "frame-timing", .module = browser_frame_timing },
            },
        }),
    });
    browser_starter_runtime.entry = .disabled;
    browser_starter_runtime.rdynamic = true;
    browser_starter_runtime.import_memory = true;
    const browser_dogfood_runtime = b.addExecutable(.{
        .name = "unpolished-peas-neon-siege",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/browser/runtime.zig"),
            .target = browser_target,
            .optimize = browser_optimize,
            .imports = &.{
                .{ .name = "unpolished-peas", .module = browser_peas },
                .{ .name = "protocol-game", .module = browser_dogfood_game },
                .{ .name = "frame-timing", .module = browser_frame_timing },
            },
        }),
    });
    browser_dogfood_runtime.entry = .disabled;
    browser_dogfood_runtime.rdynamic = true;
    browser_dogfood_runtime.import_memory = true;
    const browser_audio_smoke = b.addObject(.{
        .name = "unpolished-peas-browser-audio-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("fixtures/browser-audio-smoke.zig"),
            .target = browser_target,
            .optimize = browser_optimize,
            .imports = &.{.{ .name = "unpolished-peas", .module = browser_peas }},
        }),
    });
    const browser_audio_smoke_step = b.step("test-browser-audio-stream", "Compile the public browser PCM audio stream API");
    browser_audio_smoke_step.dependOn(&browser_audio_smoke.step);
    const browser_render_surface_smoke = b.addExecutable(.{
        .name = "unpolished-peas-browser-render-surface-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/render_surface_wasm_smoke.zig"),
            .target = browser_target,
            .optimize = browser_optimize,
            .imports = &.{.{ .name = "unpolished-peas", .module = browser_peas }},
        }),
    });
    browser_render_surface_smoke.entry = .disabled;
    browser_render_surface_smoke.rdynamic = true;
    browser_render_surface_smoke.import_memory = true;
    const browser_render_surface_test = b.addSystemCommand(&.{ "node", "script/test_browser_render_surface.mjs" });
    browser_render_surface_test.addFileArg(browser_render_surface_smoke.getEmittedBin());
    const browser_render_surface_test_step = b.step("test-browser-render-surfaces", "Run the public render-surface API through a browser-style Wasm host");
    browser_render_surface_test_step.dependOn(&browser_render_surface_test.step);
    const browser_authored_assets_smoke = b.addExecutable(.{
        .name = "unpolished-peas-browser-authored-assets-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("authored_assets_wasm_smoke.zig"),
            .target = browser_target,
            .optimize = browser_optimize,
            .imports = &.{.{ .name = "unpolished-peas", .module = browser_peas }},
        }),
    });
    browser_authored_assets_smoke.entry = .disabled;
    browser_authored_assets_smoke.rdynamic = true;
    browser_authored_assets_smoke.import_memory = true;
    const browser_authored_assets_test = b.addSystemCommand(&.{ "node", "script/test_browser_authored_assets.mjs" });
    browser_authored_assets_test.addFileArg(browser_authored_assets_smoke.getEmittedBin());
    const browser_authored_assets_test_step = b.step("test-browser-authored-assets", "Decode embedded image and TrueType font assets through browser-style Wasm");
    browser_authored_assets_test_step.dependOn(&browser_authored_assets_test.step);
    const browser_ogg_decode_smoke = b.addExecutable(.{
        .name = "unpolished-peas-browser-ogg-decode-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("browser_ogg_decode_smoke.zig"),
            .target = browser_target,
            .optimize = browser_optimize,
            .imports = &.{.{ .name = "unpolished-peas", .module = browser_peas }},
        }),
    });
    browser_ogg_decode_smoke.entry = .disabled;
    browser_ogg_decode_smoke.rdynamic = true;
    browser_ogg_decode_smoke.import_memory = true;
    const browser_ogg_decode_test = b.addSystemCommand(&.{ "node", "script/test_browser_ogg_decode.mjs" });
    browser_ogg_decode_test.addFileArg(browser_ogg_decode_smoke.getEmittedBin());
    const browser_ogg_decode_test_step = b.step("test-browser-ogg-decode", "Decode Ogg/Vorbis through the freestanding browser mixer dependency path");
    browser_ogg_decode_test_step.dependOn(&browser_ogg_decode_test.step);
    const browser_music_test_step = b.step("test-browser-music", "Run high-level incremental music playback through browser-style Wasm");
    browser_music_test_step.dependOn(&browser_ogg_decode_test.step);
    const browser_topdown_game = b.createModule(.{
        .root_source_file = b.path("examples/topdown_game.zig"),
        .target = browser_target,
        .optimize = browser_optimize,
        .imports = &.{.{ .name = "unpolished-peas", .module = browser_peas }},
    });
    const browser_topdown_runtime = b.addExecutable(.{
        .name = "unpolished-peas-topdown",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/browser/topdown_runtime.zig"),
            .target = browser_target,
            .optimize = browser_optimize,
            .imports = &.{
                .{ .name = "unpolished-peas", .module = browser_peas },
                .{ .name = "topdown-game", .module = browser_topdown_game },
                .{ .name = "frame-timing", .module = browser_frame_timing },
            },
        }),
    });
    browser_topdown_runtime.entry = .disabled;
    browser_topdown_runtime.rdynamic = true;
    browser_topdown_runtime.import_memory = true;
    const browser_puzzle_game = b.createModule(.{
        .root_source_file = b.path("examples/puzzle_game.zig"),
        .target = browser_target,
        .optimize = browser_optimize,
        .imports = &.{.{ .name = "unpolished-peas", .module = browser_peas }},
    });
    const browser_puzzle_runtime = b.addExecutable(.{
        .name = "unpolished-peas-puzzle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/browser/puzzle_runtime.zig"),
            .target = browser_target,
            .optimize = browser_optimize,
            .imports = &.{
                .{ .name = "unpolished-peas", .module = browser_peas },
                .{ .name = "puzzle-game", .module = browser_puzzle_game },
                .{ .name = "frame-timing", .module = browser_frame_timing },
            },
        }),
    });
    browser_puzzle_runtime.entry = .disabled;
    browser_puzzle_runtime.rdynamic = true;
    browser_puzzle_runtime.import_memory = true;
    const browser_platformer_game = b.createModule(.{
        .root_source_file = b.path("examples/platformer_game.zig"),
        .target = browser_target,
        .optimize = browser_optimize,
        .imports = &.{.{ .name = "unpolished-peas", .module = browser_peas }},
    });
    const browser_platformer_runtime = b.addExecutable(.{
        .name = "unpolished-peas-platformer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/browser/platformer_runtime.zig"),
            .target = browser_target,
            .optimize = browser_optimize,
            .imports = &.{
                .{ .name = "unpolished-peas", .module = browser_peas },
                .{ .name = "platformer-game", .module = browser_platformer_game },
                .{ .name = "frame-timing", .module = browser_frame_timing },
            },
        }),
    });
    browser_platformer_runtime.entry = .disabled;
    browser_platformer_runtime.rdynamic = true;
    browser_platformer_runtime.import_memory = true;
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
    const install_browser_starter_runtime = b.addInstallArtifact(browser_starter_runtime, .{
        .dest_dir = .{ .override = .{ .custom = "web" } },
        .dest_sub_path = "unpolished-peas.wasm",
    });
    const browser_starter_step = b.step("browser-starter", "Build the Seed Sprint browser runtime in zig-out/web");
    browser_starter_step.dependOn(&install_browser_starter_runtime.step);
    const install_browser_dogfood_runtime = b.addInstallArtifact(browser_dogfood_runtime, .{
        .dest_dir = .{ .override = .{ .custom = "web" } },
        .dest_sub_path = "neon-siege.wasm",
    });
    const browser_dogfood_step = b.step("browser-dogfood", "Build the Neon Siege dogfood browser runtime in zig-out/web");
    browser_dogfood_step.dependOn(&install_browser_dogfood_runtime.step);
    const install_browser_topdown_runtime = b.addInstallArtifact(browser_topdown_runtime, .{
        .dest_dir = .{ .override = .{ .custom = "web" } },
        .dest_sub_path = "unpolished-peas.wasm",
    });
    const browser_topdown_step = b.step("browser-topdown", "Build the top-down wasm32-freestanding browser runtime in zig-out/web");
    browser_topdown_step.dependOn(&install_browser_topdown_runtime.step);
    const install_browser_puzzle_runtime = b.addInstallArtifact(browser_puzzle_runtime, .{
        .dest_dir = .{ .override = .{ .custom = "web" } },
        .dest_sub_path = "unpolished-peas.wasm",
    });
    const browser_puzzle_step = b.step("browser-puzzle", "Build the puzzle wasm32-freestanding browser runtime in zig-out/web");
    browser_puzzle_step.dependOn(&install_browser_puzzle_runtime.step);
    const install_browser_platformer_runtime = b.addInstallArtifact(browser_platformer_runtime, .{
        .dest_dir = .{ .override = .{ .custom = "web" } },
        .dest_sub_path = "unpolished-peas.wasm",
    });
    const browser_platformer_step = b.step("browser-platformer", "Build the platformer wasm32-freestanding browser runtime in zig-out/web");
    browser_platformer_step.dependOn(&install_browser_platformer_runtime.step);
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
            .{ .name = "frame-timing", .module = frame_timing },
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
    const browser_webgpu_test = b.addSystemCommand(&.{ "node", "script/test_browser_webgpu.mjs" });
    browser_webgpu_test.setCwd(b.path("."));
    const browser_webgpu_test_step = b.step("test-browser-webgpu", "Test browser WebGPU canvas lifecycle");
    browser_webgpu_test_step.dependOn(&browser_webgpu_test.step);
    const browser_image_asset_test = b.addSystemCommand(&.{ "node", "script/test_browser_image_asset.mjs" });
    browser_image_asset_test.setCwd(b.path("."));
    const browser_image_asset_test_step = b.step("test-browser-image-assets", "Test browser stable image decoding and diagnostics");
    browser_image_asset_test_step.dependOn(&browser_image_asset_test.step);
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
    const browser_renderer_diagnostics_test = b.addSystemCommand(&.{ "node", "script/test_browser_renderer_diagnostics.mjs" });
    browser_renderer_diagnostics_test.setCwd(b.path("."));
    const browser_renderer_diagnostics_test_step = b.step("test-browser-renderer-diagnostics", "Test browser renderer diagnostic schema");
    browser_renderer_diagnostics_test_step.dependOn(&browser_renderer_diagnostics_test.step);
    const browser_renderer_selection_test = b.addSystemCommand(&.{ "node", "script/test_browser_renderer_selection.mjs" });
    browser_renderer_selection_test.setCwd(b.path("."));
    const browser_renderer_selection_test_step = b.step("test-browser-renderer-selection", "Test browser renderer negotiation");
    browser_renderer_selection_test_step.dependOn(&browser_renderer_selection_test.step);
    const web_package_test = b.addSystemCommand(&.{"script/test_web_package.sh"});
    web_package_test.setCwd(b.path("."));
    const web_package_test_step = b.step("test-web-package", "Validate deterministic browser package layout");
    web_package_test_step.dependOn(&web_package_test.step);
    const starter_web_package_test = b.addSystemCommand(&.{ "script/test_web_package.sh", "starter" });
    starter_web_package_test.setCwd(b.path("."));
    const starter_web_package_test_step = b.step("test-starter-web-package", "Validate the Seed Sprint browser package");
    starter_web_package_test_step.dependOn(&starter_web_package_test.step);
    const browser_chromium_test = b.addSystemCommand(&.{"script/test_browser_chromium.sh"});
    browser_chromium_test.setCwd(b.path("."));
    const browser_chromium_test_step = b.step("test-browser-chromium", "Run Chromium against the browser bundle");
    browser_chromium_test_step.dependOn(&browser_chromium_test.step);
    const browser_firefox_test = b.addSystemCommand(&.{"script/test_browser_firefox.sh"});
    browser_firefox_test.setCwd(b.path("."));
    const browser_firefox_test_step = b.step("test-browser-firefox", "Run Firefox against the browser bundle");
    browser_firefox_test_step.dependOn(&browser_firefox_test.step);
    const safari_webdriver_contract_test = b.addSystemCommand(&.{ "node", "script/test_safari_webdriver_contract.mjs" });
    safari_webdriver_contract_test.setCwd(b.path("."));
    const safari_webdriver_contract_test_step = b.step("test-safari-webdriver-contract", "Test Safari WebDriver forced-renderer contract checks");
    safari_webdriver_contract_test_step.dependOn(&safari_webdriver_contract_test.step);
    const browser_safari_test = b.addSystemCommand(&.{"script/test_browser_safari.sh"});
    browser_safari_test.setCwd(b.path("."));
    const browser_safari_test_step = b.step("test-browser-safari", "Run Safari WebDriver against forced browser renderers");
    browser_safari_test_step.dependOn(&browser_safari_test.step);
    const browser_workloads_test = b.addSystemCommand(&.{"script/test_browser_workloads.sh"});
    browser_workloads_test.setCwd(b.path("."));
    const browser_workloads_test_step = b.step("test-browser-workloads", "Run the versioned workload catalog in Chromium WebGL 2");
    browser_workloads_test_step.dependOn(&browser_workloads_test.step);
    const browser_workload_benchmark_test = b.addSystemCommand(&.{ "node", "script/test_browser_workload_benchmark.mjs" });
    browser_workload_benchmark_test.setCwd(b.path("."));
    const browser_workload_benchmark_test_step = b.step("test-browser-workload-benchmark", "Validate browser workload benchmark artifact schema");
    browser_workload_benchmark_test_step.dependOn(&browser_workload_benchmark_test.step);
    const browser_workload_artifacts_test = b.addSystemCommand(&.{"script/test_browser_workload_artifacts.sh"});
    browser_workload_artifacts_test.setCwd(b.path("."));
    const browser_workload_artifacts_test_step = b.step("test-browser-workload-artifacts", "Record forced Chromium WebGL 2 and WebGPU workload artifacts");
    browser_workload_artifacts_test_step.dependOn(&browser_workload_artifacts_test.step);
    const workload_baseline_test = b.addSystemCommand(&.{ "python3", "script/test_workload_baseline.py" });
    workload_baseline_test.setCwd(b.path("."));
    const workload_baseline_test_step = b.step("test-workload-baselines", "Test versioned workload baseline validation");
    workload_baseline_test_step.dependOn(&workload_baseline_test.step);
    const browser_workload_benchmark = b.addSystemCommand(&.{"script/record_browser_workload_artifacts.sh"});
    browser_workload_benchmark.setCwd(b.path("."));
    const browser_workload_benchmark_step = b.step("benchmark-browser-workloads", "Record forced browser workload artifacts");
    browser_workload_benchmark_step.dependOn(&browser_workload_benchmark.step);
    const web_proof_game_matrix = b.addSystemCommand(&.{"script/test_web_proof_game_matrix.sh"});
    web_proof_game_matrix.setCwd(b.path("."));
    const web_proof_game_matrix_step = b.step("test-web-proof-game-matrix", "Package and smoke every proof game in Chromium");
    web_proof_game_matrix_step.dependOn(&web_proof_game_matrix.step);
    const browser_wasm_host_test = b.addSystemCommand(&.{ "node", "script/test_browser_wasm_host.mjs" });
    browser_wasm_host_test.setCwd(b.path("."));
    browser_wasm_host_test.step.dependOn(&install_browser_runtime.step);
    const browser_wasm_host_test_step = b.step("test-browser-wasm-host", "Instantiate the browser Wasm module against its host ABI");
    browser_wasm_host_test_step.dependOn(&browser_wasm_host_test.step);

    const native_save_data = b.createModule(.{
        .root_source_file = b.path("src/native_save_data.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "unpolished-peas", .module = peas }},
    });
    const developer_diagnostics = b.createModule(.{
        .root_source_file = b.path("src/developer_diagnostics.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Experimental native-only helper for explicitly registered authored
    // assets. It is intentionally separate from the frozen root API.
    const developer_assets = b.createModule(.{
        .root_source_file = b.path("src/developer_assets.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "unpolished-peas", .module = peas }},
    });
    const browser_developer_diagnostics = b.createModule(.{
        .root_source_file = b.path("src/developer_diagnostics.zig"),
        .target = browser_target,
        .optimize = browser_optimize,
    });
    const browser_developer_diagnostics_object = b.addObject(.{
        .name = "browser-developer-diagnostics",
        .root_module = browser_developer_diagnostics,
    });
    const browser_developer_diagnostics_test_step = b.step("test-browser-developer-diagnostics", "Compile the developer diagnostics data model for browser Wasm");
    browser_developer_diagnostics_test_step.dependOn(&browser_developer_diagnostics_object.step);
    const browser_dev_test = b.addSystemCommand(&.{ "python3", "script/test_browser_dev.py" });
    browser_dev_test.setCwd(b.path("."));
    const browser_dev_test_step = b.step("test-browser-dev", "Test the local browser rebuild, server, and reload workflow");
    browser_dev_test_step.dependOn(&browser_dev_test.step);
    const sdl = b.addModule("unpolished-peas-sdl3", .{
        .root_source_file = b.path("src/backend/sdl_gpu.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "unpolished-peas", .module = peas },
            .{ .name = "native-save-data", .module = native_save_data },
            .{ .name = "frame-timing", .module = frame_timing },
            .{ .name = "developer-diagnostics", .module = developer_diagnostics },
            .{ .name = "developer-assets", .module = developer_assets },
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
    const starter_demo = addExample(b, "unpolished-peas-starter", "templates/starter/src/main.zig", target, optimize, peas, sdl);
    const install_starter_assets = b.addInstallDirectory(.{
        .source_dir = b.path("templates/starter/assets"),
        .install_dir = .prefix,
        .install_subdir = "assets",
    });
    const package_starter = b.step("package-starter", "Install the Seed Sprint starter and its assets");
    package_starter.dependOn(&b.addInstallArtifact(starter_demo, .{}).step);
    package_starter.dependOn(&install_starter_assets.step);
    const dogfood_demo = addExample(b, "unpolished-peas-neon-siege", "dogfood/neon-siege/src/main.zig", target, optimize, peas, sdl);
    const dogfood_assets = b.createModule(.{ .root_source_file = b.path("dogfood/neon-siege/embedded_assets.zig"), .target = target, .optimize = optimize });
    dogfood_demo.root_module.addImport("neon-siege-assets", dogfood_assets);
    const install_dogfood_font_license = b.addInstallFileWithDir(b.path("dogfood/neon-siege/assets/OFL.txt"), .prefix, "licenses/Basic-OFL.txt");
    const package_dogfood = b.step("package-dogfood", "Install the embedded Neon Siege dogfood game");
    package_dogfood.dependOn(&b.addInstallArtifact(dogfood_demo, .{}).step);
    package_dogfood.dependOn(&install_dogfood_font_license.step);
    const dev_demo = addExample(b, "unpolished-peas-dev-bounce", "examples/dev_bounce.zig", target, optimize, peas, sdl);
    const minimal_demo = addExample(b, "unpolished-peas-minimal", "examples/minimal.zig", target, optimize, peas, sdl);
    const tutorial_game_protocol_demo = addExample(b, "unpolished-peas-tutorial-game-protocol", "examples/tutorial_game_protocol.zig", target, optimize, peas, sdl);
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
    const render_surface_demo = addExample(b, "unpolished-peas-render-surface", "examples/render_surface.zig", target, optimize, peas, null);
    const breakout = addExample(b, "unpolished-peas-breakout", "examples/breakout.zig", target, optimize, peas, null);
    const breakout_sdl = addExample(b, "unpolished-peas-breakout-sdl", "examples/breakout_sdl.zig", target, optimize, peas, sdl);
    const topdown_sdl = addExample(b, "unpolished-peas-topdown-sdl", "examples/topdown_sdl.zig", target, optimize, peas, sdl);
    const package_topdown_sdl = b.step("package-topdown-sdl", "Install the top-down SDL sample and assets");
    package_topdown_sdl.dependOn(&b.addInstallArtifact(topdown_sdl, .{}).step);
    package_topdown_sdl.dependOn(&install_assets.step);
    const puzzle_sdl = addExample(b, "unpolished-peas-puzzle-sdl", "examples/puzzle_sdl.zig", target, optimize, peas, sdl);
    const package_puzzle_sdl = b.step("package-puzzle-sdl", "Install the puzzle SDL sample and assets");
    package_puzzle_sdl.dependOn(&b.addInstallArtifact(puzzle_sdl, .{}).step);
    package_puzzle_sdl.dependOn(&install_assets.step);
    const platformer_sdl = addExample(b, "unpolished-peas-platformer-sdl", "examples/platformer_sdl.zig", target, optimize, peas, sdl);
    const package_platformer_sdl = b.step("package-platformer-sdl", "Install the platformer SDL sample and assets");
    package_platformer_sdl.dependOn(&b.addInstallArtifact(platformer_sdl, .{}).step);
    package_platformer_sdl.dependOn(&install_assets.step);
    const audio_stress = addExample(b, "unpolished-peas-stress-audio-sdl", "examples/stress_audio_sdl.zig", target, optimize, peas, sdl);
    const packaged_assets = addExample(b, "unpolished-peas-test-packaged-assets", "examples/test_packaged_assets.zig", target, optimize, peas, null);
    const packaged_layout = addExample(b, "unpolished-peas-test-packaged-layout", "examples/test_packaged_layout.zig", target, optimize, peas, sdl);
    const install_packaged_layout = b.addInstallArtifact(packaged_layout, .{});
    const packaged_layout_step = b.step("package-layout-checker", "Install the portable package layout checker");
    packaged_layout_step.dependOn(&install_packaged_layout.step);
    const scene_tests = addExample(b, "unpolished-peas-test-scenes", "examples/test_scenes.zig", target, optimize, peas, null);
    const topdown_scene = addExample(b, "unpolished-peas-test-topdown-scene", "examples/topdown_scene.zig", target, optimize, peas, null);
    const puzzle_scene = addExample(b, "unpolished-peas-test-puzzle-scene", "examples/puzzle_scene.zig", target, optimize, peas, null);
    const platformer_scene = addExample(b, "unpolished-peas-test-platformer-scene", "examples/platformer_scene.zig", target, optimize, peas, null);
    const proof_benchmark = addExample(b, "unpolished-peas-proof-benchmark", "examples/proof_benchmark.zig", target, optimize, peas, null);
    const benchmark = b.addExecutable(.{ .name = "unpolished-peas-benchmark", .root_module = b.createModule(.{ .root_source_file = b.path("src/benchmark.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "unpolished-peas", .module = peas }} }) });
    const workload_benchmark = b.addExecutable(.{ .name = "unpolished-peas-workload-benchmark", .root_module = b.createModule(.{ .root_source_file = b.path("src/workload_benchmark.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "workload-catalog", .module = workload_catalog }} }) });
    const render_benchmark = b.addExecutable(.{ .name = "unpolished-peas-render-benchmark", .root_module = b.createModule(.{ .root_source_file = b.path("src/render_benchmark.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "unpolished-peas", .module = peas }} }) });
    const advanced_particles_benchmark = addExample(b, "unpolished-peas-advanced-particle-proof", "src/advanced_particles_benchmark.zig", target, optimize, peas, sdl);

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
    run_peas.setEnvironmentVariable("UP_TEMPLATE_ROOT", b.pathFromRoot("templates/starter"));
    run_peas.setEnvironmentVariable("UP_SCRIPT_ROOT", b.pathFromRoot("script"));
    run_peas.setEnvironmentVariable("UP_BROWSER_DEV_SERVER", b.pathFromRoot("src/browser/dev_server.py"));
    run_peas.setEnvironmentVariable("UP_REPOSITORY_ROOT", b.pathFromRoot("."));
    if (b.args) |args| run_peas.addArgs(args);
    const peas_step = b.step("peas", "Run the unpolished-peas project CLI");
    peas_step.dependOn(&run_peas.step);
    const peas_tests = b.addTest(.{ .root_module = peas_cli.root_module });
    addStb(peas_tests.root_module);
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
    run_starter.addArg(b.pathFromRoot("templates/starter"));
    if (b.args) |args| run_starter.addArgs(args);
    const new_step = b.step("new", "Create an unpolished-peas Seed Sprint project");
    new_step.dependOn(&run_starter.step);
    const starter_tests = b.addTest(.{ .root_module = starter.root_module });
    const run_starter_tests = b.addRunArtifact(starter_tests);
    const starter_test_step = b.step("test-starter", "Run generated project tests");
    starter_test_step.dependOn(&run_starter_tests.step);
    const starter_template_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("templates/starter/src/main.zig"),
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
    const starter_template_browser = b.addExecutable(.{
        .name = "starter-template-browser",
        .root_module = b.createModule(.{
            .root_source_file = b.path("templates/starter/src/game.zig"),
            .target = browser_target,
            .optimize = browser_optimize,
            .imports = &.{.{ .name = "unpolished-peas", .module = browser_peas }},
        }),
    });
    starter_template_browser.entry = .disabled;
    starter_template_browser.rdynamic = true;
    starter_template_browser.import_memory = true;
    const starter_template_browser_step = b.step("test-starter-template-browser", "Compile the starter source for the browser protocol target");
    starter_template_browser_step.dependOn(&starter_template_browser.step);
    starter_test_step.dependOn(&starter_template_browser.step);
    const starter_bundled_sdl = b.addSystemCommand(&.{"script/test_starter_bundled_sdl.sh"});
    starter_bundled_sdl.setCwd(b.path("."));
    const starter_bundled_sdl_step = b.step("test-starter-bundled-sdl", "Smoke the generated starter without pkg-config");
    starter_bundled_sdl_step.dependOn(&starter_bundled_sdl.step);
    const starter_external = b.addSystemCommand(&.{"script/test_downstream_fixture.sh"});
    starter_external.setCwd(b.path("."));
    const starter_external_step = b.step("test-starter-external", "Build the generated starter as a clean external package consumer");
    starter_external_step.dependOn(&starter_external.step);
    const starter_external_web = b.addSystemCommand(&.{"script/test_downstream_browser_fixture.sh"});
    starter_external_web.setCwd(b.path("."));
    const starter_external_web_step = b.step("test-starter-external-web", "Build the generated starter browser package outside the Peas checkout");
    starter_external_web_step.dependOn(&starter_external_web.step);
    const dogfood_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("dogfood/neon-siege/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "unpolished-peas", .module = peas },
            .{ .name = "unpolished-peas-sdl3", .module = sdl },
            .{ .name = "neon-siege-assets", .module = dogfood_assets },
        },
    }) });
    const run_dogfood_tests = b.addRunArtifact(dogfood_tests);
    const dogfood_test_step = b.step("test-dogfood", "Run the Neon Siege public-API dogfood tests");
    dogfood_test_step.dependOn(&run_dogfood_tests.step);
    const dogfood_external = b.addSystemCommand(&.{"script/test_dogfood_external.sh"});
    dogfood_external.setCwd(b.path("."));
    const dogfood_external_step = b.step("test-dogfood-external", "Build and package Neon Siege as a clean archive-style package consumer");
    dogfood_external_step.dependOn(&dogfood_external.step);
    const browser_dev_external = b.addSystemCommand(&.{"script/test_browser_dev_external.sh"});
    browser_dev_external.setCwd(b.path("."));
    const browser_dev_external_step = b.step("test-browser-dev-external", "Build browser development snapshots through release-style external consumers");
    browser_dev_external_step.dependOn(&browser_dev_external.step);

    addRunStep(b, "run-bounce", "Render the bounce demo to zig-out/bounce.ppm", demo);
    addRunStep(b, "run-bounce-sdl", "Run the unpolished-peas SDL3 bounce demo", sdl_demo);
    const run_starter_demo = b.addRunArtifact(starter_demo);
    run_starter_demo.setEnvironmentVariable("UP_ASSET_ROOT", b.pathFromRoot("templates/starter/assets"));
    if (b.args) |args| run_starter_demo.addArgs(args);
    const run_starter_step = b.step("run-starter", "Run the Seed Sprint starter from this checkout");
    run_starter_step.dependOn(&run_starter_demo.step);
    const run_dogfood_demo = b.addRunArtifact(dogfood_demo);
    if (b.args) |args| run_dogfood_demo.addArgs(args);
    const run_dogfood_step = b.step("run-dogfood", "Run the Neon Siege dogfood game from this checkout");
    run_dogfood_step.dependOn(&run_dogfood_demo.step);
    addRunStep(b, "dev-bounce", "Run the unpolished-peas live-reload demo", dev_demo);
    addRunStep(b, "run-minimal", "Run the unpolished-peas minimal SDL3 demo", minimal_demo);
    addRunStep(b, "run-tutorial-game-protocol", "Run the compiled GameProtocol tutorial example", tutorial_game_protocol_demo);
    addRunStep(b, "run-explicit-loop", "Run the advanced core explicit-loop example", explicit_loop_demo);
    addRunStep(b, "run-audio", "Run the unpolished-peas audio demo", audio_demo);
    addRunStep(b, "run-atlas", "Run the unpolished-peas atlas sprite demo", atlas_demo);
    addRunStep(b, "run-camera", "Run the unpolished-peas camera demo", camera_demo);
    addRunStep(b, "run-primitives", "Run the unpolished-peas GPU primitive demo", primitives_demo);
    addRunStep(b, "run-render-surface", "Render the software offscreen-surface example", render_surface_demo);
    addRunStep(b, "run-breakout", "Run the deterministic Breakout demo", breakout);
    addRunStep(b, "run-breakout-sdl", "Run the unpolished-peas SDL3 Breakout demo", breakout_sdl);
    addRunStep(b, "run-topdown-sdl", "Run the unpolished-peas SDL3 top-down demo", topdown_sdl);
    addRunStep(b, "run-puzzle-sdl", "Run the unpolished-peas SDL3 puzzle demo", puzzle_sdl);
    addRunStep(b, "run-platformer-sdl", "Run the unpolished-peas SDL3 platformer demo", platformer_sdl);
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
    const puzzle_smoke = b.addRunArtifact(puzzle_sdl);
    puzzle_smoke.setEnvironmentVariable("UP_ASSET_ROOT", b.pathFromRoot("examples/assets"));
    puzzle_smoke.setEnvironmentVariable("SDL_AUDIODRIVER", "dummy");
    puzzle_smoke.addArgs(&.{ "--frames", "2" });
    const puzzle_smoke_step = b.step("smoke-puzzle-sdl", "Run a bounded SDL3 puzzle smoke");
    puzzle_smoke_step.dependOn(&puzzle_smoke.step);
    const platformer_smoke = b.addRunArtifact(platformer_sdl);
    platformer_smoke.setEnvironmentVariable("UP_ASSET_ROOT", b.pathFromRoot("examples/assets"));
    platformer_smoke.setEnvironmentVariable("SDL_AUDIODRIVER", "dummy");
    platformer_smoke.addArgs(&.{ "--frames", "2" });
    const platformer_smoke_step = b.step("smoke-platformer-sdl", "Run a bounded SDL3 platformer smoke");
    platformer_smoke_step.dependOn(&platformer_smoke.step);
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
    addRunStep(b, "test-topdown-scene", "Run deterministic top-down scene hash", topdown_scene);
    addRunStep(b, "test-puzzle-scene", "Run deterministic puzzle scene hash", puzzle_scene);
    addRunStep(b, "test-platformer-scene", "Run deterministic platformer scene hash", platformer_scene);
    addRunStep(b, "benchmark", "Record deterministic engine performance metrics", benchmark);
    addRunStep(b, "benchmark-proofs", "Record deterministic proof-game performance metrics", proof_benchmark);
    addRunStep(b, "benchmark-workloads", "Record versioned native workload metrics", workload_benchmark);
    addRunStep(b, "benchmark-rendering", "Record internal Canvas and RenderSurface performance measurements", render_benchmark);
    addRunStep(b, "benchmark-advanced-particles", "Run the internal Renderer2D particle batching proof", advanced_particles_benchmark);

    const check_examples = b.step("check-examples", "Compile every example without running it");
    for ([_]*std.Build.Step.Compile{ demo, sdl_demo, starter_demo, dev_demo, minimal_demo, tutorial_game_protocol_demo, explicit_loop_demo, explicit_loop_wasm, atlas_demo, audio_demo, camera_demo, primitives_demo, render_surface_demo, breakout, breakout_sdl, topdown_sdl, puzzle_sdl, platformer_sdl, audio_stress, packaged_assets, packaged_layout, scene_tests, topdown_scene, puzzle_scene, platformer_scene, proof_benchmark, benchmark, workload_benchmark, render_benchmark, advanced_particles_benchmark, peas_cli }) |example| {
        check_examples.dependOn(&example.step);
    }
    const explicit_loop_wasm_step = b.step("test-explicit-loop-wasm", "Compile the advanced explicit-loop example for Wasm");
    explicit_loop_wasm_step.dependOn(&explicit_loop_wasm.step);

    const tests = b.addTest(.{ .root_module = peas });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unpolished-peas tests");
    test_step.dependOn(&run_tests.step);
    const render_benchmark_tests = b.addTest(.{ .root_module = render_benchmark.root_module });
    const run_render_benchmark_tests = b.addRunArtifact(render_benchmark_tests);
    const render_benchmark_test_step = b.step("test-render-benchmark", "Test internal rendering benchmark bounds");
    render_benchmark_test_step.dependOn(&run_render_benchmark_tests.step);
    test_step.dependOn(&run_render_benchmark_tests.step);
    const developer_diagnostics_tests = b.addTest(.{ .root_module = developer_diagnostics });
    const run_developer_diagnostics_tests = b.addRunArtifact(developer_diagnostics_tests);
    const developer_diagnostics_test_step = b.step("test-developer-diagnostics", "Test opt-in developer diagnostics aggregation and formatting");
    developer_diagnostics_test_step.dependOn(&run_developer_diagnostics_tests.step);
    test_step.dependOn(&run_developer_diagnostics_tests.step);
    const developer_assets_tests = b.addTest(.{ .root_module = developer_assets });
    const run_developer_assets_tests = b.addRunArtifact(developer_assets_tests);
    const developer_assets_test_step = b.step("test-hot-reload", "Test native developer authored-asset hot reload");
    developer_assets_test_step.dependOn(&run_developer_assets_tests.step);
    test_step.dependOn(&run_developer_assets_tests.step);
    const macos_hot_reload_target = b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .macos });
    const macos_hot_reload_core = b.createModule(.{
        .root_source_file = b.path("src/unpolished_peas.zig"),
        .target = macos_hot_reload_target,
        .optimize = .Debug,
    });
    addStb(macos_hot_reload_core);
    const macos_hot_reload_compile = b.addObject(.{
        .name = "macos-hot-reload-compile",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/developer_assets.zig"),
            .target = macos_hot_reload_target,
            .optimize = .Debug,
            .imports = &.{.{ .name = "unpolished-peas", .module = macos_hot_reload_core }},
        }),
    });
    const macos_hot_reload_compile_step = b.step("test-hot-reload-macos-compile", "Compile native developer asset reload helpers for macOS arm64");
    macos_hot_reload_compile_step.dependOn(&macos_hot_reload_compile.step);
    const macos_music_compile = b.addObject(.{
        .name = "macos-music-compile",
        .root_module = b.createModule(.{
            .root_source_file = b.path("music_macos_compile.zig"),
            .target = macos_hot_reload_target,
            .optimize = .Debug,
            .imports = &.{.{ .name = "unpolished-peas", .module = macos_hot_reload_core }},
        }),
    });
    const macos_music_compile_step = b.step("test-music-macos-compile", "Compile high-level incremental music for macOS arm64");
    macos_music_compile_step.dependOn(&macos_music_compile.step);
    const frame_timing_tests = b.addTest(.{ .root_module = frame_timing });
    const run_frame_timing_tests = b.addRunArtifact(frame_timing_tests);
    const frame_timing_test_step = b.step("test-frame-timing", "Test shared fixed-step host timing");
    frame_timing_test_step.dependOn(&run_frame_timing_tests.step);
    test_step.dependOn(&run_frame_timing_tests.step);
    const workload_catalog_tests = b.addTest(.{ .root_module = workload_catalog });
    const run_workload_catalog_tests = b.addRunArtifact(workload_catalog_tests);
    const workload_catalog_test_step = b.step("test-workload-catalog", "Run the versioned native rendering workload catalog");
    workload_catalog_test_step.dependOn(&run_workload_catalog_tests.step);
    test_step.dependOn(&run_workload_catalog_tests.step);
    const workload_benchmark_tests = b.addTest(.{ .root_module = workload_benchmark.root_module });
    const run_workload_benchmark_tests = b.addRunArtifact(workload_benchmark_tests);
    const workload_benchmark_test_step = b.step("test-workload-benchmark", "Validate native workload benchmark artifacts");
    workload_benchmark_test_step.dependOn(&run_workload_benchmark_tests.step);
    test_step.dependOn(&run_workload_benchmark_tests.step);
    const core_api_snapshot_module = b.createModule(.{
        .root_source_file = b.path("src/core_api_snapshot.zig"),
        .target = target,
        .optimize = optimize,
    });
    addStb(core_api_snapshot_module);
    const core_api_snapshot = b.addObject(.{ .name = "core-api-snapshot", .root_module = core_api_snapshot_module });
    const core_api_snapshot_test_step = b.step("test-core-api", "Verify the frozen core API snapshot");
    core_api_snapshot_test_step.dependOn(&core_api_snapshot.step);
    test_step.dependOn(&core_api_snapshot.step);
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
    const storage_tests = b.addTest(.{ .root_module = native_save_data });
    const run_storage_tests = b.addRunArtifact(storage_tests);
    const storage_test_step = b.step("test-storage", "Run native opaque save-data storage tests");
    storage_test_step.dependOn(&run_storage_tests.step);
    test_step.dependOn(&run_storage_tests.step);
    const render_surface_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/render_surface_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "unpolished-peas", .module = peas }},
    }) });
    const run_render_surface_tests = b.addRunArtifact(render_surface_tests);
    const render_surface_test_step = b.step("test-render-surfaces", "Run public offscreen render-surface tests");
    render_surface_test_step.dependOn(&run_render_surface_tests.step);
    test_step.dependOn(&run_render_surface_tests.step);
    const audio_game_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/audio_game_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "unpolished-peas", .module = peas }},
    }) });
    const run_audio_game_tests = b.addRunArtifact(audio_game_tests);
    const audio_game_test_step = b.step("test-audio", "Run public GameProtocol audio capability tests");
    audio_game_test_step.dependOn(&run_audio_game_tests.step);
    const music_test_step = b.step("test-music", "Run high-level incremental music lifecycle and bounded-buffer tests");
    music_test_step.dependOn(&run_audio_game_tests.step);
    test_step.dependOn(&run_audio_game_tests.step);
    const module_test_step = b.step("test-modules", "Compile and test independent core, tools, and test-fixture modules");
    module_test_step.dependOn(&run_tests.step);
    module_test_step.dependOn(&run_tools_tests.step);
    module_test_step.dependOn(&run_test_support_tests.step);
    const release_gate = b.addSystemCommand(&.{"script/release_gate.sh"});
    release_gate.setCwd(b.path("."));
    const release_gate_step = b.step("release-gate", "Run the v1 release validation gate");
    release_gate_step.dependOn(&release_gate.step);
    const release_check = b.addSystemCommand(&.{"script/test_release_validation.sh"});
    release_check.setCwd(b.path("."));
    const version_consistency = b.addSystemCommand(&.{"script/test_version_consistency.sh"});
    version_consistency.setCwd(b.path("."));
    const release_check_step = b.step("release-check", "Validate release metadata, source-archive, and published-consumer wiring");
    release_check_step.dependOn(&release_check.step);
    release_check_step.dependOn(&version_consistency.step);
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
    const puzzle_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("examples/puzzle_game.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "unpolished-peas", .module = peas }},
    }) });
    const run_puzzle_tests = b.addRunArtifact(puzzle_tests);
    const puzzle_test_step = b.step("test-puzzle", "Run deterministic puzzle tests");
    puzzle_test_step.dependOn(&run_puzzle_tests.step);
    const platformer_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("examples/platformer_game.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "unpolished-peas", .module = peas }},
    }) });
    const run_platformer_tests = b.addRunArtifact(platformer_tests);
    const platformer_test_step = b.step("test-platformer", "Run deterministic platformer tests");
    platformer_test_step.dependOn(&run_platformer_tests.step);
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
    const browser_renderer_parity = b.addSystemCommand(&.{"script/test_browser_renderer_corpus.sh"});
    browser_renderer_parity.setCwd(b.path("."));
    const browser_renderer_parity_step = b.step("test-browser-renderer-parity", "Compare forced WebGL 2 and WebGPU browser captures");
    browser_renderer_parity_step.dependOn(&browser_renderer_parity.step);
    const three_backend_renderer = b.addSystemCommand(&.{"script/test_renderer_three_backend.sh"});
    three_backend_renderer.setCwd(b.path("."));
    const three_backend_renderer_step = b.step("test-renderer-three-backend", "Compare SDL GPU, WebGL 2, and WebGPU stable-core captures");
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

fn addBrowserVorbis(mod: *std.Build.Module) void {
    mod.addIncludePath(mod.owner.path("vendor/stb"));
    mod.addCSourceFile(.{
        .file = mod.owner.path("src/vendor/stb_vorbis_wasm.c"),
        .flags = &.{ "-std=c99", "-ffreestanding", "-Wno-tautological-pointer-compare" },
    });
}

/// Browser builds use the same stb image and TrueType decoders as native
/// builds. The C sources are freestanding and receive allocation through the
/// small Zig-owned bridge imported by `image.zig`.
fn addBrowserStb(mod: *std.Build.Module) void {
    mod.addIncludePath(mod.owner.path("vendor/stb"));
    mod.addIncludePath(mod.owner.path("src/vendor"));
    mod.addCSourceFile(.{
        .file = mod.owner.path("src/vendor/stb_image_wasm.c"),
        .flags = &.{ "-std=c99", "-ffreestanding", "-Wno-tautological-pointer-compare" },
    });
    mod.addCSourceFile(.{
        .file = mod.owner.path("src/vendor/stb_truetype_wasm.c"),
        .flags = &.{ "-std=c99", "-ffreestanding", "-Wno-tautological-pointer-compare" },
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
