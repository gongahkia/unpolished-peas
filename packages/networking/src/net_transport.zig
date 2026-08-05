const std = @import("std");

pub const Peer = struct { id: u64 };
pub const Received = struct { // owns received bytes; the receiver must call deinit with the source allocator.
    from: Peer,
    bytes: []u8,
    pub fn deinit(self: *Received, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const Transport = struct { // borrows its context; the concrete transport owner must outlive this value.
    context: *anyopaque,
    poll_fn: *const fn (context: *anyopaque) anyerror!void,
    send_fn: *const fn (context: *anyopaque, to: Peer, bytes: []const u8) anyerror!void,
    receive_fn: *const fn (context: *anyopaque) ?Received,
    now_fn: *const fn (context: *anyopaque) u64,

    pub fn poll(self: Transport) !void {
        try self.poll_fn(self.context);
    }
    pub fn send(self: Transport, to: Peer, bytes: []const u8) !void {
        try self.send_fn(self.context, to, bytes);
    }
    pub fn receive(self: Transport) ?Received {
        return self.receive_fn(self.context);
    }
    pub fn now(self: Transport) u64 {
        return self.now_fn(self.context);
    }
};

pub const Loopback = struct { // owns queued packets allocated by init; Transport values borrowed from it become invalid after deinit.
    allocator: std.mem.Allocator,
    peer: Peer,
    remote: ?*Loopback = null,
    inbox: std.ArrayListUnmanaged(Received) = .{},
    now_ms: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, peer: Peer) Loopback {
        return .{ .allocator = allocator, .peer = peer };
    }
    pub fn deinit(self: *Loopback) void {
        for (self.inbox.items) |*packet| packet.deinit(self.allocator);
        self.inbox.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn pair(a: *Loopback, b: *Loopback) void {
        a.remote = b;
        b.remote = a;
    }
    pub fn advance(self: *Loopback, milliseconds: u64) void {
        self.now_ms += milliseconds;
    }
    pub fn transport(self: *Loopback) Transport {
        return .{ .context = self, .poll_fn = poll, .send_fn = send, .receive_fn = receive, .now_fn = now };
    }

    fn poll(_: *anyopaque) !void {}
    fn send(context: *anyopaque, to: Peer, bytes: []const u8) !void {
        const self: *Loopback = @ptrCast(@alignCast(context));
        const remote = self.remote orelse return error.NotConnected;
        if (remote.peer.id != to.id) return error.UnknownPeer;
        try remote.inbox.append(remote.allocator, .{ .from = self.peer, .bytes = try remote.allocator.dupe(u8, bytes) });
    }
    fn receive(context: *anyopaque) ?Received {
        const self: *Loopback = @ptrCast(@alignCast(context));
        if (self.inbox.items.len == 0) return null;
        return self.inbox.orderedRemove(0);
    }
    fn now(context: *anyopaque) u64 {
        return (@as(*Loopback, @ptrCast(@alignCast(context)))).now_ms;
    }
};

pub const UdpConfig = struct {
    bind_address: std.net.Address,
    receive_buffer_bytes: u32 = 64 * 1024,
    send_buffer_bytes: u32 = 64 * 1024,
    max_datagram_bytes: usize = @import("net_frame.zig").mtu,
    reuse_address: bool = false,
};

pub const Udp = struct { // owns its socket, receive buffer, peers, and inbox allocated by init; call deinit once.
    allocator: std.mem.Allocator,
    socket: std.posix.socket_t,
    local_address: std.net.Address,
    max_datagram_bytes: usize,
    receive_buffer: []u8,
    peers: std.AutoHashMapUnmanaged(u64, std.net.Address) = .{},
    inbox: std.ArrayListUnmanaged(Received) = .{},

    pub fn init(allocator: std.mem.Allocator, config: UdpConfig) !Udp {
        if (config.max_datagram_bytes == 0) return error.InvalidDatagramLimit;
        if (config.receive_buffer_bytes == 0 or config.send_buffer_bytes == 0) return error.InvalidSocketBufferSize;
        if (config.receive_buffer_bytes > std.math.maxInt(c_int) or config.send_buffer_bytes > std.math.maxInt(c_int)) return error.InvalidSocketBufferSize;
        if (config.bind_address.any.family != std.posix.AF.INET and config.bind_address.any.family != std.posix.AF.INET6) return error.UnsupportedAddressFamily;

        const socket = try std.posix.socket(config.bind_address.any.family, std.posix.SOCK.DGRAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC, std.posix.IPPROTO.UDP);
        errdefer std.posix.close(socket);
        if (config.reuse_address) try std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        try std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.RCVBUF, &std.mem.toBytes(@as(c_int, @intCast(config.receive_buffer_bytes))));
        try std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, &std.mem.toBytes(@as(c_int, @intCast(config.send_buffer_bytes))));
        try std.posix.bind(socket, &config.bind_address.any, config.bind_address.getOsSockLen());

        var local_address: std.net.Address = undefined;
        var local_address_len: std.posix.socklen_t = @sizeOf(std.net.Address);
        try std.posix.getsockname(socket, &local_address.any, &local_address_len);
        const receive_buffer = try allocator.alloc(u8, config.max_datagram_bytes);
        errdefer allocator.free(receive_buffer);
        return .{ .allocator = allocator, .socket = socket, .local_address = local_address, .max_datagram_bytes = config.max_datagram_bytes, .receive_buffer = receive_buffer };
    }

    pub fn deinit(self: *Udp) void {
        for (self.inbox.items) |*packet| packet.deinit(self.allocator);
        self.inbox.deinit(self.allocator);
        self.peers.deinit(self.allocator);
        self.allocator.free(self.receive_buffer);
        std.posix.close(self.socket);
        self.* = undefined;
    }

    pub fn transport(self: *Udp) Transport {
        return .{ .context = self, .poll_fn = poll, .send_fn = send, .receive_fn = receive, .now_fn = now };
    }

    pub fn registerPeer(self: *Udp, address: std.net.Address) !Peer {
        const peer = try peerForAddress(address);
        if (self.peers.get(peer.id)) |existing| {
            if (!std.net.Address.eql(existing, address)) return error.PeerIdCollision;
            return peer;
        }
        try self.peers.put(self.allocator, peer.id, address);
        return peer;
    }

    pub fn peerAddress(self: Udp, peer: Peer) !std.net.Address {
        return self.peers.get(peer.id) orelse error.UnknownPeer;
    }

    fn poll(context: *anyopaque) !void {
        const self: *Udp = @ptrCast(@alignCast(context));
        while (true) {
            var source: std.net.Address = undefined;
            var source_len: std.posix.socklen_t = @sizeOf(std.net.Address);
            const bytes_read = std.posix.recvfrom(self.socket, self.receive_buffer, 0, &source.any, &source_len) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };
            const peer = try self.registerPeer(source);
            try self.inbox.append(self.allocator, .{ .from = peer, .bytes = try self.allocator.dupe(u8, self.receive_buffer[0..bytes_read]) });
        }
    }

    fn send(context: *anyopaque, to: Peer, bytes: []const u8) !void {
        const self: *Udp = @ptrCast(@alignCast(context));
        if (bytes.len > self.max_datagram_bytes) return error.DatagramTooLarge;
        const address = try self.peerAddress(to);
        const bytes_sent = try std.posix.sendto(self.socket, bytes, 0, &address.any, address.getOsSockLen());
        if (bytes_sent != bytes.len) return error.ShortDatagram;
    }

    fn receive(context: *anyopaque) ?Received {
        const self: *Udp = @ptrCast(@alignCast(context));
        if (self.inbox.items.len == 0) return null;
        return self.inbox.orderedRemove(0);
    }

    fn now(_: *anyopaque) u64 {
        return @intCast(std.time.milliTimestamp());
    }

    fn peerForAddress(address: std.net.Address) !Peer {
        var hasher = std.hash.Wyhash.init(0);
        switch (address.any.family) {
            std.posix.AF.INET => {
                hasher.update("ipv4");
                hasher.update(std.mem.asBytes(&address.in.sa.addr));
                hasher.update(std.mem.asBytes(&address.in.sa.port));
            },
            std.posix.AF.INET6 => {
                hasher.update("ipv6");
                hasher.update(&address.in6.sa.addr);
                hasher.update(std.mem.asBytes(&address.in6.sa.port));
                hasher.update(std.mem.asBytes(&address.in6.sa.scope_id));
            },
            else => return error.UnsupportedAddressFamily,
        }
        return .{ .id = hasher.final() };
    }
};

test "loopback transport owns packets and exposes time without platform types" {
    var a = Loopback.init(std.testing.allocator, .{ .id = 1 });
    defer a.deinit();
    var b = Loopback.init(std.testing.allocator, .{ .id = 2 });
    defer b.deinit();
    Loopback.pair(&a, &b);
    const sender = a.transport();
    const receiver = b.transport();
    try sender.poll();
    try sender.send(.{ .id = 2 }, "hello");
    var packet = receiver.receive().?;
    defer packet.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 1), packet.from.id);
    try std.testing.expectEqualStrings("hello", packet.bytes);
    a.advance(17);
    try std.testing.expectEqual(@as(u64, 17), sender.now());
    try std.testing.expectError(error.UnknownPeer, sender.send(.{ .id = 3 }, "x"));
}

test "nonblocking UDP transports exchange local datagrams" {
    var server = try Udp.init(std.testing.allocator, .{ .bind_address = try std.net.Address.parseIp("127.0.0.1", 0), .receive_buffer_bytes = 16 * 1024, .send_buffer_bytes = 16 * 1024 });
    defer server.deinit();
    var client = try Udp.init(std.testing.allocator, .{ .bind_address = try std.net.Address.parseIp("127.0.0.1", 0), .receive_buffer_bytes = 16 * 1024, .send_buffer_bytes = 16 * 1024 });
    defer client.deinit();
    const client_transport = client.transport();
    const server_transport = server.transport();

    try client_transport.poll();
    const server_peer = try client.registerPeer(server.local_address);
    try client_transport.send(server_peer, "request");
    var request = try receiveWithin(server_transport, 100);
    defer request.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("request", request.bytes);
    try std.testing.expectEqual(client.local_address.getPort(), (try server.peerAddress(request.from)).getPort());

    try server_transport.send(request.from, "response");
    var response = try receiveWithin(client_transport, 100);
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("response", response.bytes);
    try std.testing.expectError(error.UnknownPeer, client_transport.send(.{ .id = 0 }, "x"));
    try std.testing.expectError(error.DatagramTooLarge, client_transport.send(server_peer, &([_]u8{0} ** (@import("net_frame.zig").mtu + 1))));
}

fn receiveWithin(transport: Transport, timeout_ms: u64) !Received {
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (std.time.milliTimestamp() < deadline) {
        try transport.poll();
        if (transport.receive()) |packet| return packet;
        std.Thread.sleep(std.time.ns_per_ms);
    }
    return error.DatagramTimeout;
}
