const std = @import("std");
const socket_backend = @import("socket_backend.zig");

pub const Ipv4Error = error{ InvalidLiteral, AddressFamilyMismatch, AddressInUse, AddressNotAvailable, AlreadyBound, BindFailed };

pub const Ipv4Address = struct {
    octets: [4]u8,
    port: u16,

    pub fn parse(literal: []const u8, port: u16) Ipv4Error!Ipv4Address {
        const address = std.net.Address.parseIp4(literal, port) catch return error.InvalidLiteral;
        var octets: [4]u8 = undefined;
        @memcpy(&octets, std.mem.asBytes(&address.in.sa.addr));
        return .{ .octets = octets, .port = address.getPort() };
    }

    pub fn wildcard(port: u16) Ipv4Address {
        return .{ .octets = .{ 0, 0, 0, 0 }, .port = port };
    }

    pub fn to_native(self: Ipv4Address) std.net.Address {
        return std.net.Address.initIp4(self.octets, self.port);
    }

    pub fn from_native(address: std.net.Address) Ipv4Error!Ipv4Address {
        if (address.any.family != std.posix.AF.INET) return error.AddressFamilyMismatch;
        var octets: [4]u8 = undefined;
        @memcpy(&octets, std.mem.asBytes(&address.in.sa.addr));
        return .{ .octets = octets, .port = address.getPort() };
    }
};

pub fn bind(socket: *socket_backend.Socket, address: Ipv4Address) Ipv4Error!void {
    const native = address.to_native();
    std.posix.bind(socket.handle, &native.any, native.getOsSockLen()) catch |err| return switch (err) {
        error.AddressInUse => error.AddressInUse,
        error.AddressNotAvailable => error.AddressNotAvailable,
        error.AlreadyBound => error.AlreadyBound,
        else => error.BindFailed,
    };
}

test "IPv4 literals convert to native wildcard and peer addresses" {
    const peer = try Ipv4Address.parse("127.0.0.1", 9000);
    try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, peer.octets);
    try std.testing.expectEqual(@as(u16, 9000), peer.port);
    try std.testing.expectEqual(peer, try Ipv4Address.from_native(peer.to_native()));
    try std.testing.expectEqual(Ipv4Address{ .octets = .{ 0, 0, 0, 0 }, .port = 0 }, Ipv4Address.wildcard(0));
}

test "IPv4 literals and bind lifecycle reject invalid input" {
    try std.testing.expectError(error.InvalidLiteral, Ipv4Address.parse("127.0.0", 1));
    try std.testing.expectError(error.AddressFamilyMismatch, Ipv4Address.from_native(std.net.Address.initIp6(.{0} ** 16, 0, 0, 0)));
    var socket = try socket_backend.Socket.open(.udp);
    defer socket.close();
    try bind(&socket, Ipv4Address.wildcard(0));
}
