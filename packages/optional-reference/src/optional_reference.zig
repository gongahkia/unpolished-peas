const core = @import("minna-san-core");
const protocol = @import("minna-san-protocol");
const transport = @import("minna-san-transport");
const topology = @import("minna-san-topology");
const state = @import("minna-san-state");
const runtime = @import("minna-san-runtime");
const c_abi = @import("minna-san-c-abi");

pub const package_name = "optional_reference";

comptime {
    _ = core.package_name;
    _ = protocol.package_name;
    _ = transport.package_name;
    _ = topology.package_name;
    _ = state.package_name;
    _ = runtime.package_name;
    _ = c_abi.package_name;
}

test "optional-reference package boundary" {
    try @import("std").testing.expectEqualStrings("optional_reference", package_name);
}
