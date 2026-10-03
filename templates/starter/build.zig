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
        .name = "seed-sprint",
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
    const run_step = b.step("run", "Run Seed Sprint");
    run_step.dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = exe.root_module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run Seed Sprint's deterministic tests");
    test_step.dependOn(&run_tests.step);

    // `zig build` already installs this layout. The named step makes the
    // distributable desktop output discoverable: zig-out/bin + zig-out/assets.
    const package_step = b.step("package", "Build the portable Seed Sprint desktop layout");
    package_step.dependOn(b.getInstallStep());

    const browser_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const browser_optimize = b.option(std.builtin.OptimizeMode, "browser-optimize", "Optimization mode for the browser Wasm runtime") orelse .ReleaseSmall;
    const browser_peas = b.dependency("unpolished_peas", .{
        .target = browser_target,
        .optimize = browser_optimize,
        .with_sdl = false,
    });
    const browser_game = b.createModule(.{
        .root_source_file = b.path("src/game.zig"),
        .target = browser_target,
        .optimize = browser_optimize,
        .imports = &.{.{ .name = "unpolished-peas", .module = browser_peas.module("unpolished-peas-browser-core") }},
    });
    const browser_runtime = browser_peas.module("unpolished-peas-browser-runtime");
    browser_runtime.addImport("protocol-game", browser_game);
    const browser = b.addExecutable(.{
        .name = "seed-sprint",
        .root_module = browser_runtime,
    });
    browser.entry = .disabled;
    browser.rdynamic = true;
    browser.import_memory = true;

    const install_browser = b.addInstallArtifact(browser, .{
        .dest_dir = .{ .override = .{ .custom = "web" } },
        .dest_sub_path = "unpolished-peas.wasm",
    });
    const install_browser_runtime = b.addInstallDirectory(.{
        .source_dir = browser_peas.path("src/browser"),
        .install_dir = .prefix,
        .install_subdir = "web",
        .include_extensions = &.{".mjs"},
    });
    const install_browser_assets = b.addInstallDirectory(.{
        .source_dir = b.path("assets"),
        .install_dir = .prefix,
        .install_subdir = "web/assets",
    });
    const install_browser_font = b.addInstallFileWithDir(browser_peas.path("src/fixtures/text/debug-5x7-v1.json"), .{ .custom = "web" }, "debug-font-v1.json");
    const web_files = b.addWriteFiles();
    const index_html = web_files.add("index.html", "<!doctype html><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><link rel=\"icon\" href=\"data:,\"><title>Seed Sprint</title><canvas data-unpolished-peas data-game=\"seed-sprint\" width=\"160\" height=\"90\" tabindex=\"0\"></canvas><script type=\"module\" src=\"./bootstrap.mjs\"></script>\n");
    const install_browser_index = b.addInstallFileWithDir(index_html, .{ .custom = "web" }, "index.html");
    const web_step = b.step("web", "Build a self-contained Seed Sprint browser directory in zig-out/web");
    web_step.dependOn(&install_browser.step);
    web_step.dependOn(&install_browser_runtime.step);
    web_step.dependOn(&install_browser_assets.step);
    web_step.dependOn(&install_browser_font.step);
    web_step.dependOn(&install_browser_index.step);
}
