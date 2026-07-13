const std = @import("std");

pub const Peer = struct { id: u64 };
pub const Received = struct {
    from: Peer,
    bytes: []u8,
    pub fn deinit(self: *Received, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const Transport = struct {
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

pub const Loopback = struct {
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
