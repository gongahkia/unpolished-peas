const std = @import("std");
const core = @import("minna-san-core");
const protocol = @import("minna-san-protocol");
const transport = @import("minna-san-transport");
const topology = @import("minna-san-topology");
const state = @import("minna-san-state");
const runtime = @import("minna-san-runtime");
const c_abi = @import("minna-san-c-abi");

pub const stable_modules = [_][]const u8{
    "minna-san-core",
    "minna-san-protocol",
    "minna-san-transport",
    "minna-san-topology",
    "minna-san-state",
    "minna-san-runtime",
    "minna-san-c-abi",
};

pub fn isStableModule(name: []const u8) bool {
    for (stable_modules) |module_name| {
        if (std.mem.eql(u8, name, module_name)) return true;
    }
    return false;
}

fn contains(comptime names: []const []const u8, name: []const u8) bool {
    inline for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

fn expectExactPublicDeclarations(comptime namespace: type, comptime expected: []const []const u8) !void {
    const declarations = comptime std.meta.declarations(namespace);
    try std.testing.expectEqual(expected.len, declarations.len);
    inline for (expected) |name| try std.testing.expect(@hasDecl(namespace, name));
    inline for (declarations) |declaration| try std.testing.expect(contains(expected, declaration.name));
}

test "stable module inventory is exact" {
    try std.testing.expectEqual(@as(usize, 7), stable_modules.len);
    for (stable_modules) |module_name| try std.testing.expect(isStableModule(module_name));
    try std.testing.expect(!isStableModule("minna-san-optional-reference"));
    try std.testing.expect(!isStableModule("minna-san-networking"));
    try std.testing.expect(!isStableModule("minna-san-services"));
}

test "stable public symbols are exact" {
    try expectExactPublicDeclarations(core, &.{"package_name"});
    try expectExactPublicDeclarations(protocol, &.{"package_name"});
    try expectExactPublicDeclarations(transport, &.{"package_name"});
    try expectExactPublicDeclarations(topology, &.{"package_name"});
    try expectExactPublicDeclarations(state, &.{"package_name"});
    try expectExactPublicDeclarations(runtime, &.{"package_name"});
    try expectExactPublicDeclarations(c_abi, &.{"package_name"});
}
