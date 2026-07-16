const std = @import("std");
const naming = @import("v1_naming.zig");
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

pub const unsupported_reference_modules = [_][]const u8{
    "minna-san-networking",
    "minna-san-services",
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

test "unsupported references are excluded from the v1 SDK" {
    try std.testing.expectEqual(@as(usize, 2), unsupported_reference_modules.len);
    for (unsupported_reference_modules) |module_name| {
        try std.testing.expect(!isStableModule(module_name));
        for (stable_modules) |stable_module_name| try std.testing.expect(!std.mem.eql(u8, stable_module_name, module_name));
    }
}

test "stable public symbols are exact" {
    try expectExactPublicDeclarations(core, &.{
        "ErrorClass",
        "CResult",
        "ZigError",
        "all_errors",
        "class_for_error",
        "error_for_class",
        "c_result_for_class",
        "class_for_c_result",
        "c_result_for_error",
        "error_for_c_result",
        "c_result_from_code",
        "Ownership",
        "BorrowedBuffer",
        "OwnedBuffer",
        "TransferError",
        "TransferredBuffer",
        "TimeNs",
        "ClockError",
        "Clock",
        "CheckedClock",
        "ManualClock",
        "Capability",
        "CapabilityError",
        "CapabilityConfig",
        "package_name",
    });
    try expectExactPublicDeclarations(protocol, &.{
        "WireVersion",
        "ExtensionRange",
        "WireEnvelope",
        "CompatibilityError",
        "v1_version",
        "extension_range",
        "validate_version",
        "validate_extension",
        "validate_envelope",
        "package_name",
    });
    try expectExactPublicDeclarations(transport, &.{"package_name"});
    try expectExactPublicDeclarations(topology, &.{"package_name"});
    try expectExactPublicDeclarations(state, &.{"package_name"});
    try expectExactPublicDeclarations(runtime, &.{
        "ConfigError",
        "SdkConfig",
        "Sdk",
        "SdkConfigBuilder",
        "HandleError",
        "ResourceHandle",
        "ResourceRegistry",
        "SdkBuffer",
        "EventMode",
        "EventOwnership",
        "EventBuffer",
        "MessageEvent",
        "OverflowEvent",
        "EventKind",
        "Event",
        "EventEnvelope",
        "EventOrderError",
        "EventOrder",
        "PollRuntimeError",
        "PollRuntime",
        "ManagedRuntimeError",
        "ManagedRuntime",
        "DirectDispatch",
        "SdkVersion",
        "runtime_version",
        "abi_version",
        "feature_version",
        "wire_version",
        "package_name",
    });
    try expectExactPublicDeclarations(c_abi, &.{
        "CAbiVersion",
        "CAbiHandle",
        "c_abi_version",
        "minna_san_abi_version",
        "minna_san_abi_supports_version",
        "package_name",
    });
}

test "stable public symbols follow namespace policy" {
    try naming.expectZigNamespace(core);
    try naming.expectZigNamespace(protocol);
    try naming.expectZigNamespace(transport);
    try naming.expectZigNamespace(topology);
    try naming.expectZigNamespace(state);
    try naming.expectZigNamespace(runtime);
    try naming.expectZigNamespace(c_abi);
}
