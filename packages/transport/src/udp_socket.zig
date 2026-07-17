const std = @import("std");
const socket_backend = @import("socket_backend.zig");
const ipv4 = @import("ipv4.zig");

pub const UdpSocketError = error{ UnsupportedConfiguration, BindFailed, ConnectFailed };
pub const UdpDatagramError = error{ DatagramTooLarge, ReceiveBufferTooSmall, InvalidSourceAddress, WouldBlock, SendFailed, ReceiveFailed };
pub const max_ipv4_datagram_bytes: usize = 65_507;

pub const ReceivedDatagram = struct {
    bytes: []u8,
    source: ipv4.Ipv4Address,
};

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

    pub fn send_to(self: *UdpSocket, payload: []const u8, peer: ipv4.Ipv4Address) UdpDatagramError!usize {
        if (payload.len > max_ipv4_datagram_bytes) return error.DatagramTooLarge;
        const native = peer.to_native();
        const sent = std.posix.sendto(self.socket.handle, payload, 0, &native.any, native.getOsSockLen()) catch |err| return switch (err) {
            error.WouldBlock => error.WouldBlock,
            error.MessageTooBig => error.DatagramTooLarge,
            else => error.SendFailed,
        };
        if (sent != payload.len) return error.SendFailed;
        return sent;
    }

    pub fn receive_from(self: *UdpSocket, storage: []u8) UdpDatagramError!ReceivedDatagram {
        if (storage.len < max_ipv4_datagram_bytes) return error.ReceiveBufferTooSmall;
        var native = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
        var source_length = native.getOsSockLen();
        const received = std.posix.recvfrom(self.socket.handle, storage[0..max_ipv4_datagram_bytes], 0, &native.any, &source_length) catch |err| return switch (err) {
            error.WouldBlock => error.WouldBlock,
            else => error.ReceiveFailed,
        };
        return .{
            .bytes = storage[0..received],
            .source = ipv4.Ipv4Address.from_native(native) catch return error.InvalidSourceAddress,
        };
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

test "UDP datagrams send receive and report caller-owned source buffers" {
    var receiver = try UdpSocket.init(.{});
    defer receiver.close();
    try receiver.bind(ipv4.Ipv4Address.wildcard(0));
    const receiver_address = try ipv4.Ipv4Address.parse("127.0.0.1", (try local_address(&receiver)).port);

    var sender = try UdpSocket.init(.{});
    defer sender.close();
    try std.testing.expectEqual(@as(usize, 8), try sender.send_to("datagram", receiver_address));

    var storage: [max_ipv4_datagram_bytes]u8 = undefined;
    const received = try receive_with_retry(&receiver, storage[0..]);
    try std.testing.expectEqualStrings("datagram", received.bytes);
    try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, received.source.octets);
    try std.testing.expect(received.source.port != 0);
}

test "UDP datagrams reject oversized payloads and undersized receive storage" {
    var socket = try UdpSocket.init(.{});
    defer socket.close();
    const oversized = [_]u8{0} ** (max_ipv4_datagram_bytes + 1);
    try std.testing.expectError(error.DatagramTooLarge, socket.send_to(&oversized, ipv4.Ipv4Address.wildcard(1)));
    var short_storage: [max_ipv4_datagram_bytes - 1]u8 = undefined;
    try std.testing.expectError(error.ReceiveBufferTooSmall, socket.receive_from(short_storage[0..]));
}

test "bounded UDP datagram fuzz corpus retains payload boundaries" {
    var receiver = try UdpSocket.init(.{});
    defer receiver.close();
    try receiver.bind(ipv4.Ipv4Address.wildcard(0));
    const receiver_address = try ipv4.Ipv4Address.parse("127.0.0.1", (try local_address(&receiver)).port);
    var sender = try UdpSocket.init(.{});
    defer sender.close();
    var storage: [max_ipv4_datagram_bytes]u8 = undefined;
    var payload: [512]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x9eb5_4d31_7ac8_f602);
    const random = prng.random();
    var iteration: usize = 0;
    while (iteration < 64) : (iteration += 1) {
        const length = random.uintLessThan(usize, payload.len + 1);
        random.bytes(payload[0..length]);
        try std.testing.expectEqual(length, try sender.send_to(payload[0..length], receiver_address));
        const received = try receive_with_retry(&receiver, storage[0..]);
        try std.testing.expectEqualSlices(u8, payload[0..length], received.bytes);
    }
}

fn local_address(socket: *UdpSocket) !ipv4.Ipv4Address {
    var native = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
    var address_length = native.getOsSockLen();
    try std.posix.getsockname(socket.socket.handle, &native.any, &address_length);
    return ipv4.Ipv4Address.from_native(native);
}

fn receive_with_retry(socket: *UdpSocket, storage: []u8) !ReceivedDatagram {
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        return socket.receive_from(storage) catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
    }
    return error.WouldBlock;
}
