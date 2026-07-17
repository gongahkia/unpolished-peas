const std = @import("std");
const ipv4 = @import("ipv4.zig");
const udp_socket = @import("udp_socket.zig");

pub const max_udp_send_batch: usize = 64;
pub const UdpSendBatchError = error{ EmptySlots, TooManySlots };

pub const UdpSendStatus = enum {
    pending,
    sent,
    would_block,
    datagram_too_large,
    failed,
};

pub const UdpSendSlot = struct {
    payload: []const u8,
    destination: ipv4.Ipv4Address,
    status: UdpSendStatus = .pending,
    bytes_sent: usize = 0,
};

pub const UdpSendBatch = struct {
    sent: usize = 0,
    would_block: usize = 0,
    failed: usize = 0,
};

pub fn send_batch(socket: *udp_socket.UdpSocket, slots: []UdpSendSlot) UdpSendBatchError!UdpSendBatch {
    if (slots.len == 0) return error.EmptySlots;
    if (slots.len > max_udp_send_batch) return error.TooManySlots;
    var batch = UdpSendBatch{};
    for (slots) |*slot| {
        slot.status = .pending;
        slot.bytes_sent = 0;
        const sent = socket.send_to(slot.payload, slot.destination) catch |err| switch (err) {
            error.WouldBlock => {
                slot.status = .would_block;
                batch.would_block += 1;
                continue;
            },
            error.DatagramTooLarge => {
                slot.status = .datagram_too_large;
                batch.failed += 1;
                continue;
            },
            else => {
                slot.status = .failed;
                batch.failed += 1;
                continue;
            },
        };
        slot.status = .sent;
        slot.bytes_sent = sent;
        batch.sent += 1;
    }
    return batch;
}

fn local_address(socket: *udp_socket.UdpSocket) !ipv4.Ipv4Address {
    var native = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
    var address_length = native.getOsSockLen();
    try std.posix.getsockname(socket.socket.handle, &native.any, &address_length);
    return ipv4.Ipv4Address.from_native(native);
}

fn receive_with_retry(socket: *udp_socket.UdpSocket, storage: []u8) !udp_socket.ReceivedDatagram {
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

test "UDP send batches report each bounded message result" {
    var receiver = try udp_socket.UdpSocket.init(.{});
    defer receiver.close();
    try receiver.bind(ipv4.Ipv4Address.wildcard(0));
    const endpoint = try ipv4.Ipv4Address.parse("127.0.0.1", (try local_address(&receiver)).port);
    var sender = try udp_socket.UdpSocket.init(.{});
    defer sender.close();
    var slots = [_]UdpSendSlot{
        .{ .payload = "one", .destination = endpoint },
        .{ .payload = "two", .destination = endpoint },
    };
    const batch = try send_batch(&sender, slots[0..]);
    try std.testing.expectEqual(@as(usize, 2), batch.sent);
    try std.testing.expectEqual(UdpSendStatus.sent, slots[0].status);
    try std.testing.expectEqual(@as(usize, 3), slots[0].bytes_sent);

    var first_storage: [udp_socket.max_ipv4_datagram_bytes]u8 = undefined;
    var second_storage: [udp_socket.max_ipv4_datagram_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("one", (try receive_with_retry(&receiver, first_storage[0..])).bytes);
    try std.testing.expectEqualStrings("two", (try receive_with_retry(&receiver, second_storage[0..])).bytes);
}

test "UDP send batches report invalid payloads without retaining a queue" {
    var socket = try udp_socket.UdpSocket.init(.{});
    defer socket.close();
    const oversized = [_]u8{0} ** (udp_socket.max_ipv4_datagram_bytes + 1);
    var oversized_slots = [_]UdpSendSlot{.{ .payload = &oversized, .destination = ipv4.Ipv4Address.wildcard(1) }};
    const batch = try send_batch(&socket, oversized_slots[0..]);
    try std.testing.expectEqual(@as(usize, 1), batch.failed);
    try std.testing.expectEqual(UdpSendStatus.datagram_too_large, oversized_slots[0].status);
    try std.testing.expectError(error.EmptySlots, send_batch(&socket, &.{}));
}
