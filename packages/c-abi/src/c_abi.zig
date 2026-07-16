const core = @import("minna-san-core");
const runtime = @import("minna-san-runtime");

pub const package_name = "c_abi";

comptime {
    _ = core.package_name;
    _ = runtime.package_name;
}

test "C ABI package boundary" {
    try @import("std").testing.expectEqualStrings("c_abi", package_name);
}
