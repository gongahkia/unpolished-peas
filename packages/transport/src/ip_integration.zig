const std = @import("std");
const endpoint_selection = @import("endpoint_selection.zig");
const ipv4 = @import("ipv4.zig");
const ipv6 = @import("ipv6.zig");
const socket_backend = @import("socket_backend.zig");
const udp_socket = @import("udp_socket.zig");

fn local_ipv4_address(socket: *udp_socket.UdpSocket) !ipv4.Ipv4Address {
    var native = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
    var length = native.getOsSockLen();
    try std.posix.getsockname(socket.socket.handle, &native.any, &length);
    return ipv4.Ipv4Address.from_native(native);
}

test "isolated IPv4 UDP endpoints exchange loopback datagrams" {
    var receiver = try udp_socket.UdpSocket.init(.{});
    defer receiver.close();
    try receiver.bind(ipv4.Ipv4Address.wildcard(0));
    const endpoint = try ipv4.Ipv4Address.parse("127.0.0.1", (try local_ipv4_address(&receiver)).port);
    var sender = try udp_socket.UdpSocket.init(.{});
    defer sender.close();
    _ = try sender.send_to("v4", endpoint);
    var storage: [udp_socket.max_ipv4_datagram_bytes]u8 = undefined;
    var received: ?udp_socket.ReceivedDatagram = null;
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        received = receiver.receive_from(storage[0..]) catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        break;
    }
    try std.testing.expectEqualStrings("v4", (received orelse unreachable).bytes);
}

test "isolated IPv6 UDP endpoints bind native loopback addresses" {
    var receiver = try socket_backend.Socket.open_with_family(.udp, std.posix.AF.INET6);
    defer receiver.close();
    try ipv6.bind(&receiver, ipv6.Ipv6Address.wildcard(0));
    var native = std.net.Address.initIp6(.{0} ** 16, 0, 0, 0);
    var length = native.getOsSockLen();
    try std.posix.getsockname(receiver.handle, &native.any, &length);
    const endpoint = ipv6.Ipv6Address{ .octets = .{0} ** 15 ++ .{1}, .port = native.getPort(), .scope_id = 0 };
    var sender = try socket_backend.Socket.open_with_family(.udp, std.posix.AF.INET6);
    defer sender.close();
    const destination = endpoint.to_native();
    _ = try std.posix.sendto(sender.handle, "v6", 0, &destination.any, destination.getOsSockLen());
    var storage: [2]u8 = undefined;
    var source = std.net.Address.initIp6(.{0} ** 16, 0, 0, 0);
    var source_length = source.getOsSockLen();
    var received: ?usize = null;
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        received = std.posix.recvfrom(receiver.handle, storage[0..], 0, &source.any, &source_length) catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        break;
    }
    try std.testing.expectEqual(@as(usize, 2), received orelse unreachable);
    try std.testing.expectEqualStrings("v6", storage[0..]);
}

test "dual-stack endpoint selection requires explicit platform support" {
    const support = endpoint_selection.PlatformSupport{ .ipv4 = true, .ipv6 = true, .dual_stack = true };
    try std.testing.expectEqual(endpoint_selection.EndpointMode.dual_stack, try endpoint_selection.select_endpoint_mode(.dual_stack, support));
    try std.testing.expectError(error.EndpointModeUnsupported, endpoint_selection.select_endpoint_mode(.dual_stack, .{ .ipv4 = true, .ipv6 = true, .dual_stack = false }));
}
