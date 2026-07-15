const std = @import("std");
const hook = @import("build_hook.zig");

pub fn applyHook(name: []const u8, dependency: *std.Build.Dependency, root_module: *std.Build.Module) void {
    if (!std.mem.eql(u8, name, hook.name)) @panic("undeclared effects build hook");
    hook.apply(dependency, root_module);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const effects = b.addModule("unpolished-peas-effects", .{
        .root_source_file = b.path("src/effects.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = effects });
    const run = b.addRunArtifact(tests);
    const step = b.step("test", "Test the unpolished-peas effects package");
    step.dependOn(&run.step);
}
