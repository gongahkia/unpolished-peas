const std = @import("std");
const socket_backend = @import("socket_backend.zig");
const ipv4 = @import("ipv4.zig");

pub const UdpSocketError = error{ UnsupportedConfiguration, BindFailed, ConnectFailed };

pub const UdpSocketConfig = struct {
    nonblocking: bool = true,
};

pub const UdpSocket = struct {
    socket: socket_backend.Socket,

    pub fn init(config: UdpSocketConfig) UdpSocketError!UdpSocket {
        if (!config.nonblocking) return error.UnsupportedConfiguration;
        return .{ .socket = socket_backend.Socket.open(.udp) catch return error.BindFailed };
    }

    pub fn bind(self: *UdpSocket, address: ipv4.Ipv4Address) UdpSocketError!void {
        ipv4.bind(&self.socket, address) catch return error.BindFailed;
    }

    pub fn connect(self: *UdpSocket, peer: ipv4.Ipv4Address) UdpSocketError!void {
        const native = peer.to_native();
        std.posix.connect(self.socket.handle, &native.any, native.getOsSockLen()) catch return error.ConnectFailed;
    }

    pub fn reconfigure(self: *UdpSocket, config: UdpSocketConfig) UdpSocketError!void {
        _ = self;
        if (!config.nonblocking) return error.UnsupportedConfiguration;
    }

    pub fn close(self: *UdpSocket) void {
        self.socket.close();
        self.* = undefined;
    }
};

test "UDP sockets create bind connect and close nonblocking endpoints" {
    var socket = try UdpSocket.init(.{});
    defer socket.close();
    try socket.bind(ipv4.Ipv4Address.wildcard(0));
    try socket.connect(try ipv4.Ipv4Address.parse("127.0.0.1", 9));
    try socket.reconfigure(.{});
}

test "UDP sockets reject blocking reconfiguration" {
    try std.testing.expectError(error.UnsupportedConfiguration, UdpSocket.init(.{ .nonblocking = false }));
}
