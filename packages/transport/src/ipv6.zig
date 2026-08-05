const std = @import("std");
const socket_backend = @import("socket_backend.zig");

pub const Ipv6Error = error{ InvalidLiteral, AddressFamilyMismatch, AddressInUse, AddressNotAvailable, AlreadyBound, BindFailed };

pub const Ipv6Address = struct {
    octets: [16]u8,
    port: u16,
    scope_id: u32,

    pub fn parse(literal: []const u8, port: u16) Ipv6Error!Ipv6Address {
        const address = std.net.Address.parseIp6(literal, port) catch return error.InvalidLiteral;
        return .{ .octets = address.in6.sa.addr, .port = address.getPort(), .scope_id = address.in6.sa.scope_id };
    }

    pub fn wildcard(port: u16) Ipv6Address {
        return .{ .octets = .{0} ** 16, .port = port, .scope_id = 0 };
    }

    pub fn to_native(self: Ipv6Address) std.net.Address {
        return std.net.Address.initIp6(self.octets, self.port, 0, self.scope_id);
    }

    pub fn from_native(address: std.net.Address) Ipv6Error!Ipv6Address {
        if (address.any.family != std.posix.AF.INET6) return error.AddressFamilyMismatch;
        return .{ .octets = address.in6.sa.addr, .port = address.getPort(), .scope_id = address.in6.sa.scope_id };
    }
};

pub fn bind(socket: *socket_backend.Socket, address: Ipv6Address) Ipv6Error!void {
    const native = address.to_native();
    std.posix.bind(socket.handle, &native.any, native.getOsSockLen()) catch |err| return switch (err) {
        error.AddressInUse => error.AddressInUse,
        error.AddressNotAvailable => error.AddressNotAvailable,
        error.AlreadyBound => error.AlreadyBound,
        else => error.BindFailed,
    };
}

test "IPv6 literals preserve scopes and native wildcard conversion" {
    const peer = try Ipv6Address.parse("::1%7", 9000);
    try std.testing.expectEqual(@as(u32, 7), peer.scope_id);
    try std.testing.expectEqual(peer, try Ipv6Address.from_native(peer.to_native()));
    try std.testing.expectEqual(Ipv6Address{ .octets = .{0} ** 16, .port = 0, .scope_id = 0 }, Ipv6Address.wildcard(0));
}

test "IPv6 literals reject invalid input and bind wildcards" {
    try std.testing.expectError(error.InvalidLiteral, Ipv6Address.parse("::1%scope", 1));
    try std.testing.expectError(error.AddressFamilyMismatch, Ipv6Address.from_native(std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0)));
    var socket = try socket_backend.Socket.open_with_family(.udp, std.posix.AF.INET6);
    defer socket.close();
    try bind(&socket, Ipv6Address.wildcard(0));
}
