const networking = @import("minna-san-networking");

pub const package_name = "minna-san-services";

test "services package identity" {
    _ = networking;
    try @import("std").testing.expectEqualStrings("minna-san-services", package_name);
}
