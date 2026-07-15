const std = @import("std");
const effects_build = @import("unpolished_peas_effects");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const enable_hook = b.option(bool, "effects-hook", "Opt into the declared effects build hook") orelse false;
    const effects = b.dependency("unpolished_peas_effects", .{ .target = target, .optimize = optimize });
    const module = b.createModule(.{
        .root_source_file = b.path(if (enable_hook) "src/hooked.zig" else "src/plain.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (enable_hook) {
        effects_build.applyHook("effects-build", effects, module);
        if (!module.import_table.contains("unpolished-peas-effects")) @panic("declared effects hook did not add its module import");
    } else if (module.import_table.contains("unpolished-peas-effects")) @panic("effects hook ran without explicit opt-in");
    const tests = b.addTest(.{ .root_module = module });
    const run = b.addRunArtifact(tests);
    const step = b.step("test", "Test explicit extension hook selection");
    step.dependOn(&run.step);
}
