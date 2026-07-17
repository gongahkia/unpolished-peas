const core = @import("minna-san-core");
const protocol = @import("minna-san-protocol");
const transport = @import("minna-san-transport");
const shard_directory = @import("shard_directory.zig");
const shard_handoff = @import("shard_handoff.zig");
const routed_peer_group = @import("routed_peer_group.zig");
const peer_group_membership = @import("peer_group_membership.zig");

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
pub const PeerGroupId = routed_peer_group.PeerGroupId;
pub const PeerGroupPeerId = routed_peer_group.PeerGroupPeerId;
pub const PeerGroupState = routed_peer_group.PeerGroupState;
pub const PeerGroupPath = routed_peer_group.PeerGroupPath;
pub const PeerGroupRoute = routed_peer_group.PeerGroupRoute;
pub const RoutedPeerGroupError = routed_peer_group.RoutedPeerGroupError;
pub const RoutedPeerGroupConfig = routed_peer_group.RoutedPeerGroupConfig;
pub const RoutedPeerGroupInfo = routed_peer_group.RoutedPeerGroupInfo;
pub const RoutedPeerGroups = routed_peer_group.RoutedPeerGroups;
pub const MembershipEventKind = peer_group_membership.MembershipEventKind;
pub const MembershipAuthorization = peer_group_membership.MembershipAuthorization;
pub const MembershipEvent = peer_group_membership.MembershipEvent;
pub const PeerGroupMembershipError = peer_group_membership.PeerGroupMembershipError;
pub const PeerGroupMembershipConfig = peer_group_membership.PeerGroupMembershipConfig;
pub const PeerGroupMembership = peer_group_membership.PeerGroupMembership;

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
    _ = @import("routed_peer_group.zig");
    _ = @import("peer_group_membership.zig");
}
