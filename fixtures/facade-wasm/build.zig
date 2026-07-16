const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi });
    const peas = b.dependency("unpolished_peas", .{ .target = target, .optimize = optimize, .with_sdl = false });
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "unpolished-peas", .module = peas.module("unpolished-peas") }},
    });
    const wasm = b.addExecutable(.{ .name = "facade-wasm-consumer", .root_module = module });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    wasm.import_memory = true;
    b.installArtifact(wasm);
}
