const std = @import("std");

pub const name = "effects-build";

pub fn apply(dependency: *std.Build.Dependency, root_module: *std.Build.Module) void {
    root_module.addImport("unpolished-peas-effects", dependency.module("unpolished-peas-effects"));
}
