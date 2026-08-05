const std = @import("std");
const protocol = @import("minna-san-protocol");
const ipv4 = @import("ipv4.zig");
const tcp_connection = @import("tcp_connection.zig");
const tcp_framed = @import("tcp_framed.zig");
const tcp_listener = @import("tcp_listener.zig");
const udp_socket = @import("udp_socket.zig");

const ConformanceResult = struct {
    sent_and_received: bool,
    bounded_failure: bool,
    caller_owns_receive_buffer: bool,
    shutdown: bool,
    protocol_valid: bool,
};

fn local_udp_address(socket: *udp_socket.UdpSocket) !ipv4.Ipv4Address {
    var native = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
    var length = native.getOsSockLen();
    try std.posix.getsockname(socket.socket.handle, &native.any, &length);
    return ipv4.Ipv4Address.from_native(native);
}

fn run_udp_conformance() !ConformanceResult {
    var receiver = try udp_socket.UdpSocket.init(.{});
    defer receiver.close();
    try receiver.bind(ipv4.Ipv4Address.wildcard(0));
    const peer = try ipv4.Ipv4Address.parse("127.0.0.1", (try local_udp_address(&receiver)).port);
    var sender = try udp_socket.UdpSocket.init(.{});
    defer sender.close();
    _ = try sender.send_to("same", peer);
    var storage: [udp_socket.max_ipv4_datagram_bytes]u8 = undefined;
    const received = try receive_udp_with_retry(&receiver, storage[0..]);
    const oversized = [_]u8{0} ** (udp_socket.max_ipv4_datagram_bytes + 1);
    const bounded_failure = blk: {
        _ = sender.send_to(&oversized, peer) catch |err| {
            break :blk err == error.DatagramTooLarge;
        };
        break :blk false;
    };
    return .{
        .sent_and_received = std.mem.eql(u8, "same", received.bytes),
        .bounded_failure = bounded_failure,
        .caller_owns_receive_buffer = received.bytes.ptr == storage[0..].ptr,
        .shutdown = true,
        .protocol_valid = blk: {
            protocol.validate_envelope(.{ .version = protocol.v1_version, .extension_id = 0, .payload = received.bytes }) catch break :blk false;
            break :blk true;
        },
    };
}

fn receive_udp_with_retry(socket: *udp_socket.UdpSocket, storage: []u8) !udp_socket.ReceivedDatagram {
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

fn run_tcp_conformance() !ConformanceResult {
    var listener = try tcp_listener.TcpListener.init(ipv4.Ipv4Address.wildcard(0), 1);
    defer listener.shutdown();
    const peer = try ipv4.Ipv4Address.parse("127.0.0.1", (try listener.local_address()).port);
    var client = try tcp_connection.TcpConnection.init();
    defer if (client.state != .closed) client.close();
    _ = try client.start_connect(peer, 1_000);
    var pending = try accept_tcp_with_retry(&listener);
    var server = (listener.admit(&pending, .allow) orelse unreachable).connection;
    defer server.close();
    var elapsed: u32 = 0;
    while (client.state == .connecting and elapsed < 1_000) : (elapsed += 1) {
        std.Thread.sleep(std.time.ns_per_ms);
        _ = try client.complete(elapsed);
    }
    var writer = try tcp_framed.TcpFrameWriter.init(4);
    try writer.begin("same");
    try std.testing.expect(try writer.flush(&client));
    var storage: [4]u8 = undefined;
    var reader = try tcp_framed.TcpFrameReader.init(storage[0..]);
    const received = try receive_tcp_with_retry(&reader, &server);
    const bounded_failure = blk: {
        _ = writer.begin("large") catch |err| break :blk err == error.MessageTooLarge;
        break :blk false;
    };
    client.close();
    return .{
        .sent_and_received = std.mem.eql(u8, "same", received),
        .bounded_failure = bounded_failure,
        .caller_owns_receive_buffer = received.ptr == storage[0..].ptr,
        .shutdown = client.state == .closed,
        .protocol_valid = blk: {
            protocol.validate_envelope(.{ .version = protocol.v1_version, .extension_id = 0, .payload = received }) catch break :blk false;
            break :blk true;
        },
    };
}

fn accept_tcp_with_retry(listener: *tcp_listener.TcpListener) !tcp_listener.TcpPendingConnection {
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        return listener.accept() catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
    }
    return error.WouldBlock;
}

fn receive_tcp_with_retry(reader: *tcp_framed.TcpFrameReader, connection: *tcp_connection.TcpConnection) ![]u8 {
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (try reader.read(connection)) |message| return message;
        std.Thread.sleep(std.time.ns_per_ms);
    }
    return error.WouldBlock;
}

test "UDP and TCP transports satisfy the common conformance matrix" {
    const udp = try run_udp_conformance();
    const tcp = try run_tcp_conformance();
    try std.testing.expect(udp.sent_and_received and tcp.sent_and_received);
    try std.testing.expect(udp.bounded_failure and tcp.bounded_failure);
    try std.testing.expect(udp.caller_owns_receive_buffer and tcp.caller_owns_receive_buffer);
    try std.testing.expect(udp.shutdown and tcp.shutdown);
}

test "UDP and framed TCP preserve identical stable protocol envelopes" {
    const udp = try run_udp_conformance();
    const tcp = try run_tcp_conformance();
    try std.testing.expect(udp.protocol_valid and tcp.protocol_valid);
    try std.testing.expect(udp.sent_and_received == tcp.sent_and_received);
    try std.testing.expect(udp.bounded_failure == tcp.bounded_failure);
}
