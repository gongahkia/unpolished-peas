const std = @import("std");

pub const WireVersion = struct {
    major: u16,
    minor: u16,
};

pub const ExtensionRange = struct {
    first: u16,
    last: u16,

    pub fn contains(self: ExtensionRange, extension_id: u16) bool {
        return extension_id >= self.first and extension_id <= self.last;
    }
};

pub const WireEnvelope = struct {
    version: WireVersion,
    extension_id: u16,
    payload: []const u8,
};

pub const CompatibilityError = error{ VersionMismatch, UnsupportedExtension };
pub const v1_version = WireVersion{ .major = 1, .minor = 0 };
pub const extension_range = ExtensionRange{ .first = 0x8000, .last = 0xbfff };

pub fn validate_version(version: WireVersion) CompatibilityError!void {
    if (version.major != v1_version.major or version.minor > v1_version.minor) return error.VersionMismatch;
}

pub fn validate_extension(extension_id: u16) CompatibilityError!void {
    if (extension_id != 0 and !extension_range.contains(extension_id)) return error.UnsupportedExtension;
}

pub fn validate_envelope(envelope: WireEnvelope) CompatibilityError!void {
    try validate_version(envelope.version);
    try validate_extension(envelope.extension_id);
}

test "v1 envelopes accept the negotiated version and extension range" {
    try validate_envelope(.{ .version = v1_version, .extension_id = 0, .payload = "core" });
    try validate_envelope(.{ .version = v1_version, .extension_id = extension_range.first, .payload = "extension" });
    try validate_envelope(.{ .version = v1_version, .extension_id = extension_range.last, .payload = "extension" });
}

test "incompatible versions and extension IDs are rejected" {
    try std.testing.expectError(error.VersionMismatch, validate_version(.{ .major = 0, .minor = 0 }));
    try std.testing.expectError(error.VersionMismatch, validate_version(.{ .major = 1, .minor = 1 }));
    try std.testing.expectError(error.UnsupportedExtension, validate_extension(1));
    try std.testing.expectError(error.UnsupportedExtension, validate_extension(0xc000));
}
