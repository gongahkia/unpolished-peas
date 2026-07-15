pub const channel = @import("net_channel.zig");
pub const codec = @import("net_codec.zig");
pub const contract = @import("net_contract.zig");
pub const fault = @import("net_fault.zig");
pub const frame = @import("net_frame.zig");
pub const handshake = @import("net_handshake.zig");
pub const migration = @import("net_migration.zig");
pub const nat = @import("net_nat.zig");
pub const p2p = @import("net_p2p.zig");
pub const peer = @import("net_peer.zig");
pub const session = @import("net_session.zig");
pub const snapshot = @import("net_snapshot.zig");
pub const transport = @import("net_transport.zig");

pub fn networking(comptime core: type) type {
    return struct {
        pub const channel = @import("net_channel.zig");
        pub const codec = @import("net_codec.zig");
        pub const contract = @import("net_contract.zig");
        pub const fault = @import("net_fault.zig");
        pub const frame = @import("net_frame.zig");
        pub const handshake = @import("net_handshake.zig");
        pub const migration = @import("net_migration.zig");
        pub const nat = @import("net_nat.zig");
        pub const p2p = @import("net_p2p.zig");
        pub const peer = @import("net_peer.zig");
        pub const session = @import("net_session.zig");
        pub const snapshot = @import("net_snapshot.zig");
        pub const sync = @import("net_sync.zig").sync(core);
        pub const transport = @import("net_transport.zig");
    };
}

pub fn multiplayerMatrix(comptime core: type) type {
    return @import("net_multiplayer_matrix.zig").matrix(core);
}

pub fn replication(comptime ecs: type) type {
    return @import("net_ecs_replication.zig").replication(ecs);
}

test {
    _ = @import("net_channel.zig");
    _ = @import("net_codec.zig");
    _ = @import("net_contract.zig");
    _ = @import("net_ecs_replication.zig");
    _ = @import("net_fault.zig");
    _ = @import("net_frame.zig");
    _ = @import("net_handshake.zig");
    _ = @import("net_migration.zig");
    _ = @import("net_nat.zig");
    _ = @import("net_p2p.zig");
    _ = @import("net_peer.zig");
    _ = @import("net_session.zig");
    _ = @import("net_snapshot.zig");
    _ = @import("net_transport.zig");
}
