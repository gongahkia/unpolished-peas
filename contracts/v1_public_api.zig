const std = @import("std");
const naming = @import("v1_naming.zig");
const core = @import("minna-san-core");
const protocol = @import("minna-san-protocol");
const transport = @import("minna-san-transport");
const topology = @import("minna-san-topology");
const state = @import("minna-san-state");
const runtime = @import("minna-san-runtime");
const c_abi = @import("minna-san-c-abi");

pub const pre_release_modules = [_][]const u8{
    "minna-san-core",
    "minna-san-protocol",
    "minna-san-transport",
    "minna-san-topology",
    "minna-san-state",
    "minna-san-runtime",
    "minna-san-c-abi",
};

pub const excluded_reference_modules = [_][]const u8{
    "minna-san-networking",
    "minna-san-services",
};

pub fn isPreReleaseModule(name: []const u8) bool {
    for (pre_release_modules) |module_name| {
        if (std.mem.eql(u8, name, module_name)) return true;
    }
    return false;
}

test "pre-release module baseline retains named SDK modules" {
    for (pre_release_modules) |module_name| try std.testing.expect(isPreReleaseModule(module_name));
    try std.testing.expect(!isPreReleaseModule("minna-san-optional-reference"));
    try std.testing.expect(!isPreReleaseModule("minna-san-networking"));
    try std.testing.expect(!isPreReleaseModule("minna-san-services"));
}

test "reference modules are excluded from the pre-release SDK baseline" {
    try std.testing.expectEqual(@as(usize, 2), excluded_reference_modules.len);
    for (excluded_reference_modules) |module_name| {
        try std.testing.expect(!isPreReleaseModule(module_name));
        for (pre_release_modules) |sdk_module_name| try std.testing.expect(!std.mem.eql(u8, sdk_module_name, module_name));
    }
}

test "pre-release public symbols follow namespace policy" {
    try naming.expectZigNamespace(core);
    try naming.expectZigNamespace(protocol);
    try naming.expectZigNamespace(transport);
    try naming.expectZigNamespace(topology);
    try naming.expectZigNamespace(state);
    try naming.expectZigNamespace(runtime);
    try naming.expectZigNamespace(c_abi);
}
