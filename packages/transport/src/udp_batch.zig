const std = @import("std");
const ipv4 = @import("ipv4.zig");
const udp_socket = @import("udp_socket.zig");

pub const max_udp_receive_batch: usize = 64;
pub const UdpReceiveBatchError = error{ EmptySlots, TooManySlots, ReceiveBufferTooSmall, ReceiveFailed, PollFailed };

pub const UdpReceiveSlot = struct {
    storage: []u8,
    datagram: ?udp_socket.ReceivedDatagram = null,
};

pub const UdpReceiveBatch = struct {
    received: usize = 0,
    would_block: bool = false,
    backpressured: bool = false,
};

pub fn receive_batch(socket: *udp_socket.UdpSocket, slots: []UdpReceiveSlot) UdpReceiveBatchError!UdpReceiveBatch {
    if (slots.len == 0) return error.EmptySlots;
    if (slots.len > max_udp_receive_batch) return error.TooManySlots;
    for (slots) |*slot| {
        if (slot.storage.len < udp_socket.max_ipv4_datagram_bytes) return error.ReceiveBufferTooSmall;
        slot.datagram = null;
    }

    var batch = UdpReceiveBatch{};
    for (slots) |*slot| {
        slot.datagram = socket.receive_from(slot.storage) catch |err| switch (err) {
            error.WouldBlock => {
                batch.would_block = true;
                return batch;
            },
            error.ReceiveBufferTooSmall => return error.ReceiveBufferTooSmall,
            else => return error.ReceiveFailed,
        };
        batch.received += 1;
    }
    var descriptor = [_]std.posix.pollfd{.{
        .fd = socket.socket.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = std.posix.poll(descriptor[0..], 0) catch return error.PollFailed;
    batch.backpressured = ready != 0 and descriptor[0].revents & std.posix.POLL.IN != 0;
    return batch;
}

fn local_address(socket: *udp_socket.UdpSocket) !ipv4.Ipv4Address {
    var native = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
    var address_length = native.getOsSockLen();
    try std.posix.getsockname(socket.socket.handle, &native.any, &address_length);
    return ipv4.Ipv4Address.from_native(native);
}

fn receive_batch_with_retry(socket: *udp_socket.UdpSocket, slots: []UdpReceiveSlot) !UdpReceiveBatch {
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        const batch = try receive_batch(socket, slots);
        if (batch.received != 0) return batch;
        std.Thread.sleep(std.time.ns_per_ms);
    }
    return error.ReceiveFailed;
}

test "UDP receive batches preserve source attribution and backpressure" {
    var receiver = try udp_socket.UdpSocket.init(.{});
    defer receiver.close();
    try receiver.bind(ipv4.Ipv4Address.wildcard(0));
    const endpoint = try ipv4.Ipv4Address.parse("127.0.0.1", (try local_address(&receiver)).port);
    var sender = try udp_socket.UdpSocket.init(.{});
    defer sender.close();
    _ = try sender.send_to("one", endpoint);
    _ = try sender.send_to("two", endpoint);
    _ = try sender.send_to("three", endpoint);

    var first_storage: [udp_socket.max_ipv4_datagram_bytes]u8 = undefined;
    var second_storage: [udp_socket.max_ipv4_datagram_bytes]u8 = undefined;
    var first_slots = [_]UdpReceiveSlot{
        .{ .storage = first_storage[0..] },
        .{ .storage = second_storage[0..] },
    };
    const first_batch = try receive_batch_with_retry(&receiver, first_slots[0..]);
    try std.testing.expectEqual(@as(usize, 2), first_batch.received);
    try std.testing.expect(first_batch.backpressured);
    try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, first_slots[0].datagram.?.source.octets);
    try std.testing.expectEqualStrings("one", first_slots[0].datagram.?.bytes);
    try std.testing.expectEqualStrings("two", first_slots[1].datagram.?.bytes);

    var final_storage: [udp_socket.max_ipv4_datagram_bytes]u8 = undefined;
    var final_slots = [_]UdpReceiveSlot{.{ .storage = final_storage[0..] }};
    const final_batch = try receive_batch_with_retry(&receiver, final_slots[0..]);
    try std.testing.expectEqual(@as(usize, 1), final_batch.received);
    try std.testing.expect(final_batch.would_block or !final_batch.backpressured);
    try std.testing.expectEqualStrings("three", final_slots[0].datagram.?.bytes);
}

test "UDP receive batches reject invalid bounded slot input" {
    var socket = try udp_socket.UdpSocket.init(.{});
    defer socket.close();
    try std.testing.expectError(error.EmptySlots, receive_batch(&socket, &.{}));
    var short_storage: [udp_socket.max_ipv4_datagram_bytes - 1]u8 = undefined;
    var short_slots = [_]UdpReceiveSlot{.{ .storage = short_storage[0..] }};
    try std.testing.expectError(error.ReceiveBufferTooSmall, receive_batch(&socket, short_slots[0..]));
}
