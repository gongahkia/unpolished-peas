const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const peas = b.dependency("unpolished_peas", .{ .target = target, .optimize = optimize });
    const assets = b.createModule(.{ .root_source_file = b.path("embedded_assets.zig"), .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{
        .name = "lantern-leap",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "unpolished-peas", .module = peas.module("unpolished-peas") },
                .{ .name = "unpolished-peas-sdl3", .module = peas.module("unpolished-peas-sdl3") },
                .{ .name = "lantern-leap-assets", .module = assets },
            },
        }),
    });
    b.installArtifact(exe);
    const install_font_license = b.addInstallFileWithDir(b.path("assets/OFL.txt"), .prefix, "licenses/Basic-OFL.txt");
    b.getInstallStep().dependOn(&install_font_license.step);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Run Lantern Leap");
    run_step.dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = exe.root_module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run Lantern Leap's deterministic headless tests");
    test_step.dependOn(&run_tests.step);
    const package_step = b.step("package", "Build Lantern Leap's portable desktop layout");
    package_step.dependOn(b.getInstallStep());

    const browser_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const browser_optimize = b.option(std.builtin.OptimizeMode, "browser-optimize", "Optimization mode for browser Wasm") orelse .ReleaseSmall;
    const browser_peas = b.dependency("unpolished_peas", .{ .target = browser_target, .optimize = browser_optimize, .with_sdl = false });
    const browser_assets = b.createModule(.{ .root_source_file = b.path("embedded_assets.zig"), .target = browser_target, .optimize = browser_optimize });
    const browser_game = b.createModule(.{
        .root_source_file = b.path("src/game.zig"),
        .target = browser_target,
        .optimize = browser_optimize,
        .imports = &.{
            .{ .name = "unpolished-peas", .module = browser_peas.module("unpolished-peas-browser-core") },
            .{ .name = "lantern-leap-assets", .module = browser_assets },
        },
    });
    const browser_runtime = browser_peas.module("unpolished-peas-browser-runtime");
    browser_runtime.addImport("protocol-game", browser_game);
    const browser = b.addExecutable(.{ .name = "lantern-leap", .root_module = browser_runtime });
    browser.entry = .disabled;
    browser.rdynamic = true;
    browser.import_memory = true;
    const install_browser = b.addInstallArtifact(browser, .{ .dest_dir = .{ .override = .{ .custom = "web" } }, .dest_sub_path = "lantern-leap.wasm" });
    const install_runtime = b.addInstallDirectory(.{ .source_dir = browser_peas.path("src/browser"), .install_dir = .prefix, .install_subdir = "web", .include_extensions = &.{".mjs"} });
    const install_font_license_web = b.addInstallFileWithDir(b.path("assets/OFL.txt"), .{ .custom = "web/licenses" }, "Basic-OFL.txt");
    const install_font = b.addInstallFileWithDir(browser_peas.path("src/fixtures/text/debug-5x7-v1.json"), .{ .custom = "web" }, "debug-font-v1.json");
    const web_files = b.addWriteFiles();
    const index = web_files.add("index.html", "<!doctype html><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><link rel=\"icon\" href=\"data:,\"><title>Lantern Leap</title><canvas data-unpolished-peas data-game=\"lantern-leap\" width=\"160\" height=\"90\" tabindex=\"0\"></canvas><script type=\"module\" src=\"./bootstrap.mjs\"></script>\n");
    const install_index = b.addInstallFileWithDir(index, .{ .custom = "web" }, "index.html");
    const web_step = b.step("web", "Build Lantern Leap's self-contained browser directory");
    web_step.dependOn(&install_browser.step);
    web_step.dependOn(&install_runtime.step);
    web_step.dependOn(&install_font_license_web.step);
    web_step.dependOn(&install_font.step);
    web_step.dependOn(&install_index.step);

    const dev_web_port = b.option(u16, "dev-web-port", "Local port for `zig build dev-web`") orelse 8000;
    const dev_web_poll_ms = b.option(u32, "dev-web-poll-ms", "Polling interval for `zig build dev-web`") orelse 200;
    const dev_web_once = b.option(bool, "dev-web-once", "Build one browser development snapshot and exit") orelse false;
    const dev_web = b.addSystemCommand(&.{"python3"});
    dev_web.addFileArg(browser_peas.path("src/browser/dev_server.py"));
    dev_web.addArgs(&.{ "dev", "--project-root", b.pathFromRoot("."), "--web-dir", b.pathFromRoot("zig-out/web"), "--port", b.fmt("{d}", .{dev_web_port}), "--poll-ms", b.fmt("{d}", .{dev_web_poll_ms}) });
    if (dev_web_once) dev_web.addArg("--once");
    const dev_web_step = b.step("dev-web", "Watch, build, serve, and refresh Lantern Leap's browser game");
    dev_web_step.dependOn(&dev_web.step);
}
