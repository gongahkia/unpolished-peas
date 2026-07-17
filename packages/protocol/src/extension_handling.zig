const std = @import("std");
const envelope = @import("wire_envelope.zig");

pub const critical_extension_first: u16 = 0xc000;
pub const ExtensionHandling = enum {
    known,
    skipped_unknown,
};

pub const ExtensionHandlingError = error{ InvalidExtension, CriticalUnknownExtension };

pub fn handle_extension(extension_id: u16, known_extensions: []const u16) ExtensionHandlingError!ExtensionHandling {
    if (extension_id == 0) return .known;
    for (known_extensions) |known| if (known == extension_id) return .known;
    if (envelope.extension_range.contains(extension_id)) return .skipped_unknown;
    if (extension_id >= critical_extension_first) return error.CriticalUnknownExtension;
    return error.InvalidExtension;
}

test "unknown optional extensions are skipped and known extensions are delivered" {
    try std.testing.expectEqual(ExtensionHandling.known, try handle_extension(0, &.{}));
    try std.testing.expectEqual(ExtensionHandling.known, try handle_extension(0x8001, &.{0x8001}));
    try std.testing.expectEqual(ExtensionHandling.skipped_unknown, try handle_extension(envelope.extension_range.last, &.{}));
}

test "critical and invalid unknown extensions are rejected unambiguously" {
    try std.testing.expectError(error.CriticalUnknownExtension, handle_extension(critical_extension_first, &.{}));
    try std.testing.expectError(error.InvalidExtension, handle_extension(1, &.{}));
}
