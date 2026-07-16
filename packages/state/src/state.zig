const core = @import("minna-san-core");
const protocol = @import("minna-san-protocol");

pub const package_name = "state";

comptime {
    _ = core.package_name;
    _ = protocol.package_name;
}

test "state package boundary" {
    try @import("std").testing.expectEqualStrings("state", package_name);
}
