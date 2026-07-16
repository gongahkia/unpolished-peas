const protocol = @import("minna-san-protocol");

pub const SdkVersion = struct {
    major: u16,
    minor: u16,
    patch: u16,
};

pub fn runtime_version() SdkVersion {
    return .{ .major = 0, .minor = 1, .patch = 0 };
}

pub fn abi_version() u32 {
    return 1;
}

pub fn feature_version() u32 {
    return 1;
}

pub fn wire_version() protocol.WireVersion {
    return protocol.v1_version;
}

test "Zig consumers receive stable SDK, ABI, feature, and wire versions" {
    const runtime = runtime_version();
    try @import("std").testing.expectEqual(@as(u16, 0), runtime.major);
    try @import("std").testing.expectEqual(@as(u16, 1), runtime.minor);
    try @import("std").testing.expectEqual(@as(u16, 0), runtime.patch);
    try @import("std").testing.expectEqual(@as(u32, 1), abi_version());
    try @import("std").testing.expectEqual(@as(u32, 1), feature_version());
    try @import("std").testing.expectEqual(protocol.v1_version.major, wire_version().major);
    try @import("std").testing.expectEqual(protocol.v1_version.minor, wire_version().minor);
}
