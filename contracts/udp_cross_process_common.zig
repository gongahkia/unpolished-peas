const std = @import("std");
const runtime = @import("minna-san-runtime");

pub const Role = enum { server, client };

pub fn parsePort(value: []const u8) !u16 {
    const port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidArgument;
    if (port == 0) return error.InvalidArgument;
    return port;
}

pub fn run(role: Role, local_port: u16, peer_port: u16) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    var clock = runtime.ManualClock.init(0);
    const sdk = try runtime.SdkConfigBuilder.init().with_clock(clock.clock()).with_platform_config(.{ .limits = .{ .session_capacity = 1, .channel_capacity = 4, .listener_capacity = 1 } }).build();
    var platform = try runtime.Runtime.init(allocator, sdk);
    defer platform.deinit();
    const local = try runtime.Ipv4Address.parse("127.0.0.1", local_port);
    const peer = try runtime.Ipv4Address.parse("127.0.0.1", peer_port);
    const session = try platform.dialUdp(.{
        .endpoint = runtime.Endpoint.from_ipv4(peer),
        .family_policy = .ipv4_only,
        .platform_support = .{ .ipv4 = true, .ipv6 = false, .dual_stack = false },
        .channel = .{ .delivery = .datagram, .maximum_payload_bytes = 64, .maximum_in_flight = 4 },
        .local_address = .{ .ipv4 = local },
    });
    const channel = (try platform.pollUdpSession(session)).channel;
    if (role == .server) try std.fs.File.stdout().deprecatedWriter().writeAll("ready\n");
    switch (role) {
        .server => try runServer(&platform, allocator, session, channel),
        .client => try runClient(&platform, allocator, session, channel),
    }
    try platform.closeUdpSession(session);
    try std.fs.File.stdout().deprecatedWriter().writeAll("verified\n");
}

fn runServer(platform: *runtime.Runtime, allocator: std.mem.Allocator, session: *runtime.ResourceHandle, channel: *runtime.ResourceHandle) !void {
    var got_reliable = false;
    var got_unreliable = false;
    var acknowledged = false;
    var sent_unreliable = false;
    var attempts: usize = 0;
    while (attempts < 2_000) : (attempts += 1) {
        try receiveMessages(platform, allocator, session, &got_reliable, &got_unreliable, null, null);
        if (got_reliable and !acknowledged) {
            try sendMessage(platform, session, channel, "A:client-reliable");
            acknowledged = true;
        }
        if (got_unreliable and !sent_unreliable) {
            try sendMessage(platform, session, channel, "U:server-unreliable");
            sent_unreliable = true;
        }
        if (acknowledged and sent_unreliable) return;
        std.Thread.sleep(std.time.ns_per_ms);
    }
    return error.ExchangeTimedOut;
}

fn runClient(platform: *runtime.Runtime, allocator: std.mem.Allocator, session: *runtime.ResourceHandle, channel: *runtime.ResourceHandle) !void {
    try sendMessage(platform, session, channel, "R:client-reliable");
    try sendMessage(platform, session, channel, "U:client-unreliable");
    var got_reliable = false;
    var got_unreliable = false;
    var attempts: usize = 0;
    while (attempts < 2_000) : (attempts += 1) {
        try receiveMessages(platform, allocator, session, null, null, &got_reliable, &got_unreliable);
        if (got_reliable and got_unreliable) return;
        if (attempts != 0 and attempts % 10 == 0) try sendMessage(platform, session, channel, "R:client-reliable");
        std.Thread.sleep(std.time.ns_per_ms);
    }
    return error.ExchangeTimedOut;
}

fn receiveMessages(platform: *runtime.Runtime, allocator: std.mem.Allocator, session: *runtime.ResourceHandle, server_reliable: ?*bool, server_unreliable: ?*bool, client_reliable: ?*bool, client_unreliable: ?*bool) !void {
    var events: [2]runtime.UdpReceiveEvent = undefined;
    _ = try platform.pollUdpReceives(session, events[0..]);
    while (try platform.dequeueChannel(session)) |value| {
        var message = value;
        defer message.deinit(allocator);
        if (server_reliable) |flag| {
            if (std.mem.eql(u8, message.payload, "R:client-reliable")) flag.* = true;
        }
        if (server_unreliable) |flag| {
            if (std.mem.eql(u8, message.payload, "U:client-unreliable")) flag.* = true;
        }
        if (client_reliable) |flag| {
            if (std.mem.eql(u8, message.payload, "A:client-reliable")) flag.* = true;
        }
        if (client_unreliable) |flag| {
            if (std.mem.eql(u8, message.payload, "U:server-unreliable")) flag.* = true;
        }
    }
}

fn sendMessage(platform: *runtime.Runtime, session: *runtime.ResourceHandle, channel: *runtime.ResourceHandle, payload: []const u8) !void {
    try platform.enqueueChannel(channel, payload);
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        var events: [1]runtime.UdpSendEvent = undefined;
        const batch = try platform.flushUdpSends(session, events[0..]);
        if (batch.sent == 1) return;
        if (batch.dropped != 0 or !batch.retryable) return error.SendFailed;
        std.Thread.sleep(std.time.ns_per_ms);
    }
    return error.SendTimedOut;
}
