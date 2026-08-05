const std = @import("std");
const protocol = @import("minna-san-protocol");

fn negotiate(peer_version: protocol.WireVersion) protocol.CompatibilityError!protocol.WireVersion {
    try protocol.validate_version(peer_version);
    return protocol.v1_version;
}

test "pinned v1 peers negotiate the stable wire version" {
    const negotiated = try negotiate(.{ .major = 1, .minor = 0 });
    try std.testing.expectEqual(protocol.v1_version.major, negotiated.major);
    try std.testing.expectEqual(protocol.v1_version.minor, negotiated.minor);
    try protocol.validate_envelope(.{
        .version = negotiated,
        .extension_id = protocol.extension_range.first,
        .payload = "compatibility-vector",
    });
}

test "incompatible peer versions and extensions preserve rejection classes" {
    try std.testing.expectError(error.VersionMismatch, negotiate(.{ .major = 0, .minor = 0 }));
    try std.testing.expectError(error.VersionMismatch, negotiate(.{ .major = 1, .minor = 1 }));
    try std.testing.expectError(error.VersionMismatch, negotiate(.{ .major = 2, .minor = 0 }));
    try std.testing.expectError(error.UnsupportedExtension, protocol.validate_envelope(.{
        .version = protocol.v1_version,
        .extension_id = 0x4000,
        .payload = "incompatible-extension",
    }));
}
