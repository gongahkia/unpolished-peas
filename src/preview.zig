pub const ecs = struct {
    pub const Entity = @import("ecs.zig").Entity;
    pub const World = @import("ecs.zig").World;
    pub const Commands = @import("ecs.zig").Commands;
    pub const ComponentStore = @import("ecs.zig").ComponentStore;
};

pub const networking = struct {
    pub const Contract = @import("net_contract.zig");
    pub const Codec = @import("net_codec.zig");
    pub const Transport = @import("net_transport.zig").Transport;
    pub const LoopbackTransport = @import("net_transport.zig").Loopback;
    pub const UdpTransport = @import("net_transport.zig").Udp;
    pub const Handshake = @import("net_handshake.zig");
    pub const PeerServer = @import("net_peer.zig").Server;
    pub const PeerPacketRejection = @import("net_peer.zig").PacketRejection;
    pub const Channel = @import("net_channel.zig").Channel;
    pub const SnapshotPublisher = @import("net_snapshot.zig").Publisher;
    pub const SnapshotClient = @import("net_snapshot.zig").Client;
    pub const Host = @import("net_session.zig").Host;
    pub const Client = @import("net_session.zig").Client;
    pub const FaultNetwork = @import("net_fault.zig").Network;
};

pub const developer = struct {
    pub const InputReplay = @import("input_replay.zig").Replay;
    pub const parseInputReplay = @import("input_replay.zig").parse;
    pub const PixelEffect = @import("shader.zig").PixelEffect;
    pub const PixelEffectParameters = @import("shader.zig").Parameters;
};
