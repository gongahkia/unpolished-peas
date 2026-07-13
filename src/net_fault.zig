const std = @import("std");
const transport = @import("net_transport.zig");

pub const Config = struct {
    seed: u64,
    latency_ms: u64 = 0,
    jitter_ms: u64 = 0,
    loss_per_mille: u16 = 0,
    duplicate_per_mille: u16 = 0,
    reorder_per_mille: u16 = 0,
    reorder_delay_ms: u64 = 0,
    bandwidth_bytes_per_second: u64 = 0,
};

pub const Network = struct {
    allocator: std.mem.Allocator,
    config: Config,
    random: std.Random.DefaultPrng,
    now_ms: u64 = 0,
    next_bandwidth_slot: u64 = 0,
    flights: std.ArrayListUnmanaged(Flight) = .{},

    const Flight = struct { from: transport.Peer, to: *Endpoint, deliver_at_ms: u64, bytes: []u8 };

    pub fn init(allocator: std.mem.Allocator, config: Config) !Network {
        if (config.loss_per_mille > 1_000 or config.duplicate_per_mille > 1_000 or config.reorder_per_mille > 1_000) return error.InvalidFaultConfig;
        return .{ .allocator = allocator, .config = config, .random = std.Random.DefaultPrng.init(config.seed) };
    }

    pub fn deinit(self: *Network) void {
        for (self.flights.items) |flight| flight.to.allocator.free(flight.bytes);
        self.flights.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn advance(self: *Network, milliseconds: u64) void {
        self.now_ms +%= milliseconds;
        self.flush();
    }

    fn send(self: *Network, from: transport.Peer, to: *Endpoint, bytes: []const u8) !void {
        if (self.selected(self.config.loss_per_mille)) return;
        try self.schedule(from, to, bytes);
        if (self.selected(self.config.duplicate_per_mille)) try self.schedule(from, to, bytes);
    }

    fn schedule(self: *Network, from: transport.Peer, to: *Endpoint, bytes: []const u8) !void {
        var delay = self.config.latency_ms + self.jitter();
        if (self.selected(self.config.reorder_per_mille)) delay +%= self.config.reorder_delay_ms;
        var deliver_at = self.now_ms +% delay;
        if (self.config.bandwidth_bytes_per_second > 0) {
            deliver_at = @max(deliver_at, self.next_bandwidth_slot);
            const serial_ms = @max(@as(u64, 1), std.math.divCeil(u64, @as(u64, @intCast(bytes.len)) * 1_000, self.config.bandwidth_bytes_per_second) catch return error.InvalidFaultConfig);
            self.next_bandwidth_slot = deliver_at +% serial_ms;
        }
        try self.flights.append(self.allocator, .{ .from = from, .to = to, .deliver_at_ms = deliver_at, .bytes = try to.allocator.dupe(u8, bytes) });
        self.flush();
    }

    fn flush(self: *Network) void {
        var index: usize = 0;
        while (index < self.flights.items.len) {
            if (self.flights.items[index].deliver_at_ms > self.now_ms) {
                index += 1;
                continue;
            }
            const flight = self.flights.orderedRemove(index);
            flight.to.inbox.append(flight.to.allocator, .{ .from = flight.from, .bytes = flight.bytes }) catch flight.to.allocator.free(flight.bytes);
        }
    }

    fn selected(self: *Network, per_mille: u16) bool {
        if (per_mille == 0) return false;
        if (per_mille == 1_000) return true;
        return self.random.random().uintLessThan(u16, 1_000) < per_mille;
    }

    fn jitter(self: *Network) u64 {
        if (self.config.jitter_ms == 0) return 0;
        return self.random.random().uintLessThan(u64, self.config.jitter_ms + 1);
    }
};

pub const Endpoint = struct {
    allocator: std.mem.Allocator,
    network: *Network,
    peer: transport.Peer,
    remote: ?*Endpoint = null,
    inbox: std.ArrayListUnmanaged(transport.Received) = .{},

    pub fn init(allocator: std.mem.Allocator, network: *Network, peer: transport.Peer) Endpoint {
        return .{ .allocator = allocator, .network = network, .peer = peer };
    }

    pub fn deinit(self: *Endpoint) void {
        for (self.inbox.items) |*packet| packet.deinit(self.allocator);
        self.inbox.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn pair(a: *Endpoint, b: *Endpoint) void {
        a.remote = b;
        b.remote = a;
    }

    pub fn asTransport(self: *Endpoint) transport.Transport {
        return .{ .context = self, .poll_fn = poll, .send_fn = send, .receive_fn = receive, .now_fn = now };
    }

    fn poll(context: *anyopaque) !void {
        const self: *Endpoint = @ptrCast(@alignCast(context));
        self.network.flush();
    }

    fn send(context: *anyopaque, to: transport.Peer, bytes: []const u8) !void {
        const self: *Endpoint = @ptrCast(@alignCast(context));
        const remote = self.remote orelse return error.NotConnected;
        if (remote.peer.id != to.id) return error.UnknownPeer;
        try self.network.send(self.peer, remote, bytes);
    }

    fn receive(context: *anyopaque) ?transport.Received {
        const self: *Endpoint = @ptrCast(@alignCast(context));
        if (self.inbox.items.len == 0) return null;
        return self.inbox.orderedRemove(0);
    }

    fn now(context: *anyopaque) u64 {
        return (@as(*Endpoint, @ptrCast(@alignCast(context)))).network.now_ms;
    }
};

test "seeded faults reproduce duplicate reordered delivery and bandwidth delay" {
    const config = Config{ .seed = 7, .latency_ms = 5, .jitter_ms = 3, .duplicate_per_mille = 1_000, .reorder_per_mille = 1_000, .reorder_delay_ms = 10, .bandwidth_bytes_per_second = 1 };
    var first_network = try Network.init(std.testing.allocator, config);
    defer first_network.deinit();
    var first_sender = Endpoint.init(std.testing.allocator, &first_network, .{ .id = 1 });
    defer first_sender.deinit();
    var first_receiver = Endpoint.init(std.testing.allocator, &first_network, .{ .id = 2 });
    defer first_receiver.deinit();
    Endpoint.pair(&first_sender, &first_receiver);
    try first_sender.asTransport().send(.{ .id = 2 }, "a");
    try first_sender.asTransport().send(.{ .id = 2 }, "b");
    first_network.advance(5_000);
    var first_trace = std.ArrayList(u8).empty;
    defer first_trace.deinit(std.testing.allocator);
    while (first_receiver.asTransport().receive()) |received| {
        var packet = received;
        defer packet.deinit(std.testing.allocator);
        try first_trace.appendSlice(std.testing.allocator, packet.bytes);
    }
    try std.testing.expectEqual(@as(usize, 4), first_trace.items.len);

    var second_network = try Network.init(std.testing.allocator, config);
    defer second_network.deinit();
    var second_sender = Endpoint.init(std.testing.allocator, &second_network, .{ .id = 1 });
    defer second_sender.deinit();
    var second_receiver = Endpoint.init(std.testing.allocator, &second_network, .{ .id = 2 });
    defer second_receiver.deinit();
    Endpoint.pair(&second_sender, &second_receiver);
    try second_sender.asTransport().send(.{ .id = 2 }, "a");
    try second_sender.asTransport().send(.{ .id = 2 }, "b");
    second_network.advance(5_000);
    var second_trace = std.ArrayList(u8).empty;
    defer second_trace.deinit(std.testing.allocator);
    while (second_receiver.asTransport().receive()) |received| {
        var packet = received;
        defer packet.deinit(std.testing.allocator);
        try second_trace.appendSlice(std.testing.allocator, packet.bytes);
    }
    try std.testing.expectEqualSlices(u8, first_trace.items, second_trace.items);
}

test "fault network drops selected datagrams" {
    var network = try Network.init(std.testing.allocator, .{ .seed = 1, .loss_per_mille = 1_000 });
    defer network.deinit();
    var sender = Endpoint.init(std.testing.allocator, &network, .{ .id = 1 });
    defer sender.deinit();
    var receiver = Endpoint.init(std.testing.allocator, &network, .{ .id = 2 });
    defer receiver.deinit();
    Endpoint.pair(&sender, &receiver);
    try sender.asTransport().send(.{ .id = 2 }, "dropped");
    network.advance(1);
    try std.testing.expect(receiver.asTransport().receive() == null);
}

test "fault network reorders delayed packets and shapes bandwidth" {
    var reordered_network = try Network.init(std.testing.allocator, .{ .seed = 2, .reorder_per_mille = 1_000, .reorder_delay_ms = 10 });
    defer reordered_network.deinit();
    var reordered_sender = Endpoint.init(std.testing.allocator, &reordered_network, .{ .id = 1 });
    defer reordered_sender.deinit();
    var reordered_receiver = Endpoint.init(std.testing.allocator, &reordered_network, .{ .id = 2 });
    defer reordered_receiver.deinit();
    Endpoint.pair(&reordered_sender, &reordered_receiver);
    try reordered_sender.asTransport().send(.{ .id = 2 }, "first");
    reordered_network.config.reorder_per_mille = 0;
    try reordered_sender.asTransport().send(.{ .id = 2 }, "second");
    var first_delivered = reordered_receiver.asTransport().receive().?;
    defer first_delivered.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("second", first_delivered.bytes);
    reordered_network.advance(10);
    var second_delivered = reordered_receiver.asTransport().receive().?;
    defer second_delivered.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("first", second_delivered.bytes);

    var bandwidth_network = try Network.init(std.testing.allocator, .{ .seed = 3, .bandwidth_bytes_per_second = 1 });
    defer bandwidth_network.deinit();
    var bandwidth_sender = Endpoint.init(std.testing.allocator, &bandwidth_network, .{ .id = 1 });
    defer bandwidth_sender.deinit();
    var bandwidth_receiver = Endpoint.init(std.testing.allocator, &bandwidth_network, .{ .id = 2 });
    defer bandwidth_receiver.deinit();
    Endpoint.pair(&bandwidth_sender, &bandwidth_receiver);
    try bandwidth_sender.asTransport().send(.{ .id = 2 }, "a");
    try bandwidth_sender.asTransport().send(.{ .id = 2 }, "b");
    var immediate = bandwidth_receiver.asTransport().receive().?;
    defer immediate.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("a", immediate.bytes);
    bandwidth_network.advance(999);
    try std.testing.expect(bandwidth_receiver.asTransport().receive() == null);
    bandwidth_network.advance(1);
    var shaped = bandwidth_receiver.asTransport().receive().?;
    defer shaped.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("b", shaped.bytes);
}
