pub const package_name = "core";

test "core package boundary" {
    try @import("std").testing.expectEqualStrings("core", package_name);
}
