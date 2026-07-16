const core = @import("minna-san-core");
const envelope = @import("wire_envelope.zig");

pub const WireVersion = envelope.WireVersion;
pub const ExtensionRange = envelope.ExtensionRange;
pub const WireEnvelope = envelope.WireEnvelope;
pub const CompatibilityError = envelope.CompatibilityError;
pub const v1_version = envelope.v1_version;
pub const extension_range = envelope.extension_range;
pub const validate_version = envelope.validate_version;
pub const validate_extension = envelope.validate_extension;
pub const validate_envelope = envelope.validate_envelope;
pub const package_name = "protocol";

comptime {
    _ = core.package_name;
}

test "protocol package boundary" {
    try @import("std").testing.expectEqualStrings("protocol", package_name);
}

test {
    _ = @import("wire_envelope.zig");
}
