const core = @import("minna-san-core");
const protocol = @import("minna-san-protocol");
const transport = @import("minna-san-transport");
const shard_directory = @import("shard_directory.zig");
const shard_handoff = @import("shard_handoff.zig");

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
pub const HandoffClientId = shard_handoff.HandoffClientId;
pub const ShardHandoffId = shard_handoff.ShardHandoffId;
pub const ShardHandoffRequest = shard_handoff.ShardHandoffRequest;
pub const ShardHandoff = shard_handoff.ShardHandoff;
pub const ShardHandoffError = shard_handoff.ShardHandoffError;
pub const ShardHandoffConfig = shard_handoff.ShardHandoffConfig;
pub const ShardHandoffCoordinator = shard_handoff.ShardHandoffCoordinator;

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
    _ = @import("shard_handoff.zig");
}
