const std = @import("std");

pub fn add(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, peas: *std.Build.Module, sdl: ?*std.Build.Module, browser_target: std.Build.ResolvedTarget, browser_optimize: std.builtin.OptimizeMode, browser_peas: *std.Build.Module, frame_timing: *std.Build.Module) void {
    const counter = b.createModule(.{ .root_source_file = b.path("src/render_benchmark.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "unpolished-peas", .module = peas }} });
    const browser_counter = b.createModule(.{ .root_source_file = b.path("src/render_benchmark.zig"), .target = browser_target, .optimize = browser_optimize, .imports = &.{.{ .name = "unpolished-peas", .module = browser_peas }} });
    const build_step = b.step("build-render-capacity", "Build retained native and browser GameProtocol rendering workloads");
    const root = "render-capacity";
    const manifest = b.addWriteFiles().add("render-capacity-build.json", b.fmt("{{\"native_optimize\":\"{s}\",\"wasm_optimize\":\"{s}\",\"zig\":\"{s}\"}}\n", .{ @tagName(optimize), @tagName(browser_optimize), @import("builtin").zig_version_string }));
    build_step.dependOn(&b.addInstallFileWithDir(manifest, .{ .custom = root }, "build.json").step);
    if (sdl) |native_sdl| {
        for ([_]struct { width: u32, linear: bool }{ .{ .width = 320, .linear = false }, .{ .width = 640, .linear = false }, .{ .width = 1280, .linear = false }, .{ .width = 1280, .linear = true } }) |case| {
            const name = b.fmt("native-{d}-{s}", .{ case.width, if (case.linear) "linear" else "nearest" });
            const options = b.addOptions();
            options.addOption(u32, "width", case.width);
            options.addOption(u32, "height", case.width * 9 / 16);
            options.addOption(bool, "linear", case.linear);
            const exe = b.addExecutable(.{ .name = name, .root_module = b.createModule(.{
                .root_source_file = b.path("examples/render_capacity.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{ .{ .name = "unpolished-peas", .module = peas }, .{ .name = "unpolished-peas-sdl3", .module = native_sdl }, .{ .name = "render-counter", .module = counter } },
            }) });
            exe.root_module.addOptions("capacity-options", options);
            build_step.dependOn(&b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = root } } }).step);
        }
    }
    const reference = b.addExecutable(.{ .name = "reference", .root_module = b.createModule(.{
        .root_source_file = b.path("examples/render_capacity_reference.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "unpolished-peas", .module = peas }, .{ .name = "render-counter", .module = counter } },
    }) });
    build_step.dependOn(&b.addInstallArtifact(reference, .{ .dest_dir = .{ .override = .{ .custom = root } } }).step);
    const game = b.createModule(.{
        .root_source_file = b.path("examples/render_capacity_game.zig"),
        .target = browser_target,
        .optimize = browser_optimize,
        .imports = &.{ .{ .name = "unpolished-peas", .module = browser_peas }, .{ .name = "render-counter", .module = browser_counter } },
    });
    const wasm = b.addExecutable(.{ .name = "render-capacity", .root_module = b.createModule(.{
        .root_source_file = b.path("src/browser/runtime.zig"),
        .target = browser_target,
        .optimize = browser_optimize,
        .imports = &.{ .{ .name = "unpolished-peas", .module = browser_peas }, .{ .name = "frame-timing", .module = frame_timing }, .{ .name = "protocol-game", .module = game } },
    }) });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    wasm.import_memory = true;
    build_step.dependOn(&b.addInstallArtifact(wasm, .{ .dest_dir = .{ .override = .{ .custom = root ++ "/web" } }, .dest_sub_path = "unpolished-peas.wasm" }).step);
    build_step.dependOn(&b.addInstallDirectory(.{ .source_dir = b.path("src/browser"), .install_dir = .prefix, .install_subdir = root ++ "/web", .include_extensions = &.{".mjs"} }).step);
    build_step.dependOn(&b.addInstallFileWithDir(b.path("src/fixtures/text/debug-5x7-v1.json"), .{ .custom = root ++ "/web" }, "debug-font-v1.json").step);
    build_step.dependOn(&b.addInstallFileWithDir(b.path("examples/assets/fonts/SourceSansOFL.txt"), .{ .custom = root ++ "/web" }, "SourceSansOFL.txt").step);
    for ([_]bool{ false, true }) |verify| {
        const command = b.addSystemCommand(&.{ "node", "script/benchmark_game_rendering.mjs", "--bundle", b.getInstallPath(.prefix, root) });
        if (verify) command.addArg("--verify-only");
        command.step.dependOn(build_step);
        b.step(if (verify) "test-render-capacity" else "benchmark-game-rendering", if (verify) "Compare native and real Chromium mixed GameProtocol pixels and allocation behavior" else "Measure native and real Chromium mixed GameProtocol frames sequentially").dependOn(&command.step);
    }
}
