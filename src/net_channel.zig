const std = @import("std");
const net_codec = @import("net_codec.zig");
const transport = @import("net_transport.zig");

pub const max_payload_bytes: usize = net_codec.max_payload_bytes;
pub const header_bytes: usize = 7;

const PacketKind = enum(u8) { reliable = 1, sequenced = 2, ack = 3 };
pub const Mode = enum { reliable_ordered, unreliable_sequenced };
pub const Config = struct {
    reliable_window: usize = 32,
    resend_interval_ms: u64 = 100,
    max_retransmits: u8 = 8,
};
pub const Message = struct {
    mode: Mode,
    sequence: u32,
    payload: []u8,

    pub fn deinit(self: *Message, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
        self.* = undefined;
    }
};

pub const Channel = struct {
    allocator: std.mem.Allocator,
    peer: transport.Peer,
    config: Config,
    next_reliable_sequence: u32 = 0,
    expected_reliable_sequence: u32 = 0,
    next_sequenced_sequence: u32 = 0,
    last_sequenced_sequence: ?u32 = null,
    outgoing: std.ArrayListUnmanaged(Outgoing) = .{},
    reordered: std.ArrayListUnmanaged(Stored) = .{},
    received: std.ArrayListUnmanaged(Message) = .{},

    const Outgoing = struct { sequence: u32, payload: []u8, last_sent_at: u64, retransmits: u8 = 0 };
    const Stored = struct { sequence: u32, payload: []u8 };

    pub fn init(allocator: std.mem.Allocator, peer: transport.Peer, config: Config) !Channel {
        if (config.reliable_window == 0 or config.reliable_window > std.math.maxInt(i32) or config.resend_interval_ms == 0) return error.InvalidChannelConfig;
        return .{ .allocator = allocator, .peer = peer, .config = config };
    }

    pub fn deinit(self: *Channel) void {
        for (self.outgoing.items) |*packet| self.allocator.free(packet.payload);
        self.outgoing.deinit(self.allocator);
        for (self.reordered.items) |*packet| self.allocator.free(packet.payload);
        self.reordered.deinit(self.allocator);
        for (self.received.items) |*message| message.deinit(self.allocator);
        self.received.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn sendReliable(self: *Channel, net: transport.Transport, payload: []const u8) !void {
        if (payload.len > max_payload_bytes) return error.PayloadTooLarge;
        if (self.outgoing.items.len >= self.config.reliable_window) return error.ReliableWindowFull;
        const sequence = self.next_reliable_sequence;
        self.next_reliable_sequence +%= 1;
        try self.outgoing.append(self.allocator, .{ .sequence = sequence, .payload = try self.allocator.dupe(u8, payload), .last_sent_at = net.now() });
        errdefer {
            self.allocator.free(self.outgoing.items[self.outgoing.items.len - 1].payload);
            _ = self.outgoing.pop();
            self.next_reliable_sequence -%= 1;
        }
        try self.sendData(net, .reliable, sequence, payload);
    }

    pub fn sendUnreliable(self: *Channel, net: transport.Transport, payload: []const u8) !void {
        if (payload.len > max_payload_bytes) return error.PayloadTooLarge;
        const sequence = self.next_sequenced_sequence;
        self.next_sequenced_sequence +%= 1;
        errdefer self.next_sequenced_sequence -%= 1;
        try self.sendData(net, .sequenced, sequence, payload);
    }

    pub fn poll(self: *Channel, net: transport.Transport) !void {
        try net.poll();
        while (net.receive()) |received| {
            var packet = received;
            defer packet.deinit(self.allocator);
            if (packet.from.id != self.peer.id) continue;
            try self.handlePacket(net, packet.bytes);
        }
        try self.retransmit(net);
    }

    pub fn receive(self: *Channel) ?Message {
        if (self.received.items.len == 0) return null;
        return self.received.orderedRemove(0);
    }

    fn handlePacket(self: *Channel, net: transport.Transport, bytes: []const u8) !void {
        const decoded = try decodePacket(bytes);
        switch (decoded.kind) {
            .ack => self.acknowledge(decoded.sequence),
            .reliable => {
                try self.handleReliable(decoded.sequence, decoded.payload);
                try self.sendAck(net, decoded.sequence);
            },
            .sequenced => {
                if (self.last_sequenced_sequence) |last| if (!isAfter(decoded.sequence, last)) return;
                self.last_sequenced_sequence = decoded.sequence;
                try self.appendMessage(.unreliable_sequenced, decoded.sequence, decoded.payload);
            },
        }
    }

    fn handleReliable(self: *Channel, sequence: u32, payload: []const u8) !void {
        if (sequence == self.expected_reliable_sequence) {
            try self.appendMessage(.reliable_ordered, sequence, payload);
            self.expected_reliable_sequence +%= 1;
            return self.deliverReordered();
        }
        if (!isAfter(sequence, self.expected_reliable_sequence)) return;
        if (sequence -% self.expected_reliable_sequence >= self.config.reliable_window) return;
        for (self.reordered.items) |packet| if (packet.sequence == sequence) return;
        try self.reordered.append(self.allocator, .{ .sequence = sequence, .payload = try self.allocator.dupe(u8, payload) });
    }

    fn deliverReordered(self: *Channel) !void {
        while (true) {
            const index = self.findReordered(self.expected_reliable_sequence) orelse return;
            const packet = self.reordered.orderedRemove(index);
            try self.received.append(self.allocator, .{ .mode = .reliable_ordered, .sequence = packet.sequence, .payload = packet.payload });
            self.expected_reliable_sequence +%= 1;
        }
    }

    fn acknowledge(self: *Channel, sequence: u32) void {
        for (self.outgoing.items, 0..) |packet, index| {
            if (packet.sequence != sequence) continue;
            self.allocator.free(packet.payload);
            _ = self.outgoing.orderedRemove(index);
            return;
        }
    }

    fn retransmit(self: *Channel, net: transport.Transport) !void {
        const now = net.now();
        for (self.outgoing.items) |*packet| {
            if (now < packet.last_sent_at or now - packet.last_sent_at < self.config.resend_interval_ms) continue;
            if (packet.retransmits >= self.config.max_retransmits) return error.ReliableDeliveryFailed;
            try self.sendData(net, .reliable, packet.sequence, packet.payload);
            packet.last_sent_at = now;
            packet.retransmits += 1;
        }
    }

    fn sendAck(self: *Channel, net: transport.Transport, sequence: u32) !void {
        var bytes: [header_bytes]u8 = undefined;
        try net.send(self.peer, try encodePacket(&bytes, .ack, sequence, ""));
    }

    fn sendData(self: *Channel, net: transport.Transport, kind: PacketKind, sequence: u32, payload: []const u8) !void {
        var bytes: [header_bytes + max_payload_bytes]u8 = undefined;
        try net.send(self.peer, try encodePacket(&bytes, kind, sequence, payload));
    }

    fn appendMessage(self: *Channel, mode: Mode, sequence: u32, payload: []const u8) !void {
        try self.received.append(self.allocator, .{ .mode = mode, .sequence = sequence, .payload = try self.allocator.dupe(u8, payload) });
    }

    fn findReordered(self: Channel, sequence: u32) ?usize {
        for (self.reordered.items, 0..) |packet, index| if (packet.sequence == sequence) return index;
        return null;
    }
};

fn encodePacket(destination: []u8, kind: PacketKind, sequence: u32, payload: []const u8) ![]u8 {
    if (payload.len > max_payload_bytes) return error.PayloadTooLarge;
    const length = header_bytes + payload.len;
    if (destination.len < length) return error.BufferTooSmall;
    destination[0] = @intFromEnum(kind);
    std.mem.writeInt(u32, destination[1..5], sequence, .little);
    std.mem.writeInt(u16, destination[5..7], @intCast(payload.len), .little);
    @memcpy(destination[header_bytes..length], payload);
    return destination[0..length];
}

fn decodePacket(bytes: []const u8) !struct { kind: PacketKind, sequence: u32, payload: []const u8 } {
    if (bytes.len < header_bytes) return error.MalformedChannelPacket;
    const kind = std.meta.intToEnum(PacketKind, bytes[0]) catch return error.MalformedChannelPacket;
    const payload_len: usize = std.mem.readInt(u16, bytes[5..7], .little);
    if (payload_len > max_payload_bytes or bytes.len != header_bytes + payload_len) return error.MalformedChannelPacket;
    if (kind == .ack and payload_len != 0) return error.MalformedChannelPacket;
    return .{ .kind = kind, .sequence = std.mem.readInt(u32, bytes[1..5], .little), .payload = bytes[header_bytes..] };
}

fn isAfter(sequence: u32, reference: u32) bool {
    return sequence != reference and @as(i32, @bitCast(sequence -% reference)) > 0;
}

test "reliable channel retransmits a lost packet and delivers reordered data once" {
    var sender_endpoint = transport.Loopback.init(std.testing.allocator, .{ .id = 1 });
    defer sender_endpoint.deinit();
    var receiver_endpoint = transport.Loopback.init(std.testing.allocator, .{ .id = 2 });
    defer receiver_endpoint.deinit();
    transport.Loopback.pair(&sender_endpoint, &receiver_endpoint);
    var sender = try Channel.init(std.testing.allocator, .{ .id = 2 }, .{ .resend_interval_ms = 10 });
    defer sender.deinit();
    var receiver = try Channel.init(std.testing.allocator, .{ .id = 1 }, .{ .resend_interval_ms = 10 });
    defer receiver.deinit();

    try sender.sendReliable(sender_endpoint.transport(), "first");
    var dropped = receiver_endpoint.inbox.orderedRemove(0);
    dropped.deinit(std.testing.allocator);
    try sender.sendReliable(sender_endpoint.transport(), "second");
    try receiver.poll(receiver_endpoint.transport());
    try sender.poll(sender_endpoint.transport());
    sender_endpoint.advance(10);
    try sender.poll(sender_endpoint.transport());
    try receiver.poll(receiver_endpoint.transport());
    var dropped_ack = sender_endpoint.inbox.orderedRemove(0);
    dropped_ack.deinit(std.testing.allocator);
    sender_endpoint.advance(10);
    try sender.poll(sender_endpoint.transport());
    try receiver.poll(receiver_endpoint.transport());
    try sender.poll(sender_endpoint.transport());

    var first = receiver.receive() orelse return error.TestExpectedEqual;
    defer first.deinit(std.testing.allocator);
    var second = receiver.receive() orelse return error.TestExpectedEqual;
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(Mode.reliable_ordered, first.mode);
    try std.testing.expectEqualStrings("first", first.payload);
    try std.testing.expectEqualStrings("second", second.payload);
    try std.testing.expectEqual(@as(usize, 0), sender.outgoing.items.len);
}

test "unreliable sequenced channel discards stale reordered data" {
    var sender_endpoint = transport.Loopback.init(std.testing.allocator, .{ .id = 1 });
    defer sender_endpoint.deinit();
    var receiver_endpoint = transport.Loopback.init(std.testing.allocator, .{ .id = 2 });
    defer receiver_endpoint.deinit();
    transport.Loopback.pair(&sender_endpoint, &receiver_endpoint);
    var sender = try Channel.init(std.testing.allocator, .{ .id = 2 }, .{});
    defer sender.deinit();
    var receiver = try Channel.init(std.testing.allocator, .{ .id = 1 }, .{});
    defer receiver.deinit();

    try sender.sendUnreliable(sender_endpoint.transport(), "stale");
    try sender.sendUnreliable(sender_endpoint.transport(), "latest");
    std.mem.swap(transport.Received, &receiver_endpoint.inbox.items[0], &receiver_endpoint.inbox.items[1]);
    try receiver.poll(receiver_endpoint.transport());

    var latest = receiver.receive() orelse return error.TestExpectedEqual;
    defer latest.deinit(std.testing.allocator);
    try std.testing.expectEqual(Mode.unreliable_sequenced, latest.mode);
    try std.testing.expectEqualStrings("latest", latest.payload);
    try std.testing.expect(receiver.receive() == null);
}

test "reliable channel exchanges a datagram over local UDP" {
    var server_endpoint = try transport.Udp.init(std.testing.allocator, .{ .bind_address = try std.net.Address.parseIp("127.0.0.1", 0), .receive_buffer_bytes = 16 * 1024, .send_buffer_bytes = 16 * 1024 });
    defer server_endpoint.deinit();
    var client_endpoint = try transport.Udp.init(std.testing.allocator, .{ .bind_address = try std.net.Address.parseIp("127.0.0.1", 0), .receive_buffer_bytes = 16 * 1024, .send_buffer_bytes = 16 * 1024 });
    defer client_endpoint.deinit();
    const client_server = try client_endpoint.registerPeer(server_endpoint.local_address);
    const server_client = try server_endpoint.registerPeer(client_endpoint.local_address);
    var client = try Channel.init(std.testing.allocator, client_server, .{ .resend_interval_ms = 5 });
    defer client.deinit();
    var server = try Channel.init(std.testing.allocator, server_client, .{ .resend_interval_ms = 5 });
    defer server.deinit();

    try client.sendReliable(client_endpoint.transport(), "udp");
    var delivered = false;
    var attempts: usize = 0;
    while (!delivered and attempts < 100) : (attempts += 1) {
        try server.poll(server_endpoint.transport());
        if (server.receive()) |received| {
            var message = received;
            defer message.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings("udp", message.payload);
            delivered = true;
        }
        try client.poll(client_endpoint.transport());
        std.Thread.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(delivered);
    try client.poll(client_endpoint.transport());
    try std.testing.expectEqual(@as(usize, 0), client.outgoing.items.len);
}
