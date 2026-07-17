const core = @import("minna-san-core");
const protocol = @import("minna-san-protocol");
const transport = @import("minna-san-transport");
const shard_directory = @import("shard_directory.zig");

pub const ShardId = shard_directory.ShardId;
pub const ShardHealth = shard_directory.ShardHealth;
pub const ShardRouteKind = shard_directory.ShardRouteKind;
pub const ShardEndpoint = shard_directory.ShardEndpoint;
pub const ShardRoute = shard_directory.ShardRoute;
pub const ShardCapacity = shard_directory.ShardCapacity;
pub const ShardRegistration = shard_directory.ShardRegistration;
pub const ShardDirectoryError = shard_directory.ShardDirectoryError;
pub const ShardDirectoryConfig = shard_directory.ShardDirectoryConfig;
pub const ShardDirectory = shard_directory.ShardDirectory;

pub const package_name = "topology";

comptime {
    _ = core.package_name;
    _ = protocol.package_name;
    _ = transport.package_name;
}

test "topology package boundary" {
    try @import("std").testing.expectEqualStrings("topology", package_name);
}

test {
    _ = @import("shard_directory.zig");
}
