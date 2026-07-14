const up = @import("unpolished-peas");

pub const networking = struct {
    pub const Peer = up.NetPeer;
    pub const Transport = up.NetTransport;
    pub const Received = up.NetReceived;
    pub const LoopbackTransport = up.LoopbackTransport;
    pub const UdpTransport = up.UdpTransport;
    pub const HandshakeClient = up.HandshakeClient;
    pub const HandshakeServer = up.HandshakeServer;
    pub const Channel = up.NetChannel;
};

test "services module imports only core contracts" {
    const transport = networking.Transport;
    _ = transport;
}
