const std = @import("std");

pub fn isZigModuleName(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "minna-san-")) return false;
    return isLowerKebab(name["minna-san-".len..]);
}

pub fn isZigValueName(name: []const u8) bool {
    return isLowerSnake(name);
}

pub fn isZigTypeName(name: []const u8) bool {
    if (name.len == 0 or !std.ascii.isUpper(name[0])) return false;
    for (name[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte)) return false;
    }
    return true;
}

pub fn isCSymbolName(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "minna_san_")) return false;
    return isLowerSnake(name["minna_san_".len..]);
}

pub fn isCMacroName(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "MINNA_SAN_")) return false;
    if (name.len == "MINNA_SAN_".len) return false;
    for (name["MINNA_SAN_".len..]) |byte| {
        if (!(std.ascii.isUpper(byte) or std.ascii.isDigit(byte) or byte == '_')) return false;
    }
    return true;
}

pub fn expectZigNamespace(comptime namespace: type) !void {
    inline for (comptime std.meta.declarations(namespace)) |declaration| {
        const value = @field(namespace, declaration.name);
        const valid = if (@TypeOf(value) == type) isZigTypeName(declaration.name) else isZigValueName(declaration.name);
        try std.testing.expect(valid);
    }
}

fn isLowerKebab(name: []const u8) bool {
    if (name.len == 0 or name[0] == '-' or name[name.len - 1] == '-') return false;
    for (name) |byte| {
        if (!(std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '-')) return false;
    }
    return true;
}

fn isLowerSnake(name: []const u8) bool {
    if (name.len == 0 or name[0] == '_' or name[name.len - 1] == '_') return false;
    for (name) |byte| {
        if (!(std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '_')) return false;
    }
    return true;
}

test "stable naming accepts supported forms" {
    try std.testing.expect(isZigModuleName("minna-san-runtime"));
    try std.testing.expect(isZigValueName("package_name"));
    try std.testing.expect(isZigTypeName("RuntimeConfig"));
    try std.testing.expect(isCSymbolName("minna_san_runtime_create"));
    try std.testing.expect(isCMacroName("MINNA_SAN_RUNTIME_V1"));
}

test "stable naming rejects unsupported forms" {
    try std.testing.expect(!isZigModuleName("minna_san_runtime"));
    try std.testing.expect(!isZigValueName("PackageName"));
    try std.testing.expect(!isZigTypeName("runtime_config"));
    try std.testing.expect(!isCSymbolName("minnaSanRuntimeCreate"));
    try std.testing.expect(!isCMacroName("MINNA_SAN_runtime"));
}
