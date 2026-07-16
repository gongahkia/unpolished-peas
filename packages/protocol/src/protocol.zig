const core = @import("minna-san-core");

pub const package_name = "protocol";

comptime {
    _ = core.package_name;
}

test "protocol package boundary" {
    try @import("std").testing.expectEqualStrings("protocol", package_name);
}
