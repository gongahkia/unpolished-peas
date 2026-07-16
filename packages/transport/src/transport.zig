const core = @import("minna-san-core");
const protocol = @import("minna-san-protocol");

pub const package_name = "transport";

comptime {
    _ = core.package_name;
    _ = protocol.package_name;
}

test "transport package boundary" {
    try @import("std").testing.expectEqualStrings("transport", package_name);
}
