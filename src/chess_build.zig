const std = @import("std");
pub fn add(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, peas: *std.Build.Module, browser_target: std.Build.ResolvedTarget, browser_optimize: std.builtin.OptimizeMode, browser_peas: *std.Build.Module, frame_timing: *std.Build.Module) *std.Build.Step {
    const tests = b.step("test-chess", "Verify local chess rules, game controls, ownership and terminal states");
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |mode| {
        const counter = b.createModule(.{ .root_source_file = b.path("src/render_benchmark.zig"), .target = target, .optimize = mode, .imports = &.{.{ .name = "unpolished-peas", .module = peas }} });
        const check = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("examples/chess_game_checks.zig"),
            .target = target,
            .optimize = mode,
            .imports = &.{ .{ .name = "unpolished-peas", .module = peas }, .{ .name = "render-counter", .module = counter } },
        }) });
        tests.dependOn(&b.addRunArtifact(check).step);
    }
    const reference = b.addExecutable(.{ .name = "chess-reference", .root_module = b.createModule(.{
        .root_source_file = b.path("examples/chess_reference.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "unpolished-peas", .module = peas }},
    }) });
    const game = b.createModule(.{
        .root_source_file = b.path("examples/chess_game.zig"),
        .target = browser_target,
        .optimize = browser_optimize,
        .imports = &.{.{ .name = "unpolished-peas", .module = browser_peas }},
    });
    const wasm = b.addExecutable(.{ .name = "chess", .root_module = b.createModule(.{
        .root_source_file = b.path("src/browser/runtime.zig"),
        .target = browser_target,
        .optimize = browser_optimize,
        .imports = &.{ .{ .name = "unpolished-peas", .module = browser_peas }, .{ .name = "frame-timing", .module = frame_timing }, .{ .name = "protocol-game", .module = game } },
    }) });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    wasm.import_memory = true;
    const web = b.step("web-chess", "Package playable local two-player chess in zig-out/chess");
    web.dependOn(&b.addInstallArtifact(wasm, .{ .dest_dir = .{ .override = .{ .custom = "chess" } }, .dest_sub_path = "unpolished-peas.wasm" }).step);
    web.dependOn(&b.addInstallDirectory(.{ .source_dir = b.path("src/browser"), .install_dir = .prefix, .install_subdir = "chess", .include_extensions = &.{".mjs"} }).step);
    web.dependOn(&b.addInstallFileWithDir(b.path("src/fixtures/text/debug-5x7-v1.json"), .{ .custom = "chess" }, "debug-font-v1.json").step);
    web.dependOn(&b.addInstallFileWithDir(b.path("examples/assets/fonts/SourceSansOFL.txt"), .{ .custom = "chess" }, "SourceSansOFL.txt").step);
    const html = b.addWriteFiles().add("chess.html", "<!doctype html><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><link rel=\"icon\" href=\"data:,\"><title>Peas / local two-player chess</title><canvas data-unpolished-peas data-peas-shell width=\"640\" height=\"480\" tabindex=\"0\"></canvas><script type=\"module\" src=\"./bootstrap.mjs\"></script>\n");
    web.dependOn(&b.addInstallFileWithDir(html, .{ .custom = "chess" }, "index.html").step);
    const browser = b.addSystemCommand(&.{ "node", "script/test_chess_browser.mjs", "--bundle", b.getInstallPath(.prefix, "chess") });
    const probe = b.addExecutable(.{ .name = "chess-rules", .root_module = b.createModule(.{ .root_source_file = b.path("examples/chess/rules_probe.zig"), .target = browser_target, .optimize = .ReleaseFast }) });
    probe.entry = .disabled;
    probe.rdynamic = true;
    browser.addFileArg(reference.getEmittedBin());
    browser.addFileArg(probe.getEmittedBin());
    browser.step.dependOn(web);
    b.step("test-browser-chess", "Play a complete local chess game in real Chromium and compare native pixels").dependOn(&browser.step);
    return tests;
}
