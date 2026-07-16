const core = @import("minna-san-core");
const protocol = @import("minna-san-protocol");
const transport = @import("minna-san-transport");

pub const package_name = "topology";

comptime {
    _ = core.package_name;
    _ = protocol.package_name;
    _ = transport.package_name;
}

test "topology package boundary" {
    try @import("std").testing.expectEqualStrings("topology", package_name);
}
