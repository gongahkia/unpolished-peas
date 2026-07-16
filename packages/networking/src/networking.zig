pub const package_name = "minna-san-networking";

test "networking package identity" {
    try @import("std").testing.expectEqualStrings("minna-san-networking", package_name);
}
