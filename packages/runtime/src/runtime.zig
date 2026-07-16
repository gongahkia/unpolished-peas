const core = @import("minna-san-core");
const protocol = @import("minna-san-protocol");
const transport = @import("minna-san-transport");
const topology = @import("minna-san-topology");
const state = @import("minna-san-state");
const sdk_config = @import("sdk_config.zig");

pub const ConfigError = sdk_config.ConfigError;
pub const SdkConfig = sdk_config.SdkConfig;
pub const Sdk = sdk_config.Sdk;
pub const SdkConfigBuilder = sdk_config.SdkConfigBuilder;
pub const package_name = "runtime";

comptime {
    _ = core.package_name;
    _ = protocol.package_name;
    _ = transport.package_name;
    _ = topology.package_name;
    _ = state.package_name;
}

test "runtime package boundary" {
    try @import("std").testing.expectEqualStrings("runtime", package_name);
}

test {
    _ = @import("sdk_config.zig");
}
