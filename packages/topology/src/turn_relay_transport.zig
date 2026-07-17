const core = @import("minna-san-core");
const protocol = @import("minna-san-protocol");
const channels = @import("turn_channels.zig");
const permissions = @import("turn_permissions.zig");

pub const TurnRelayTransportError = channels.TurnChannelError || permissions.TurnPermissionError || error{ OutputTooSmall, SendFailed, UnauthorizedPeer };
pub const TurnRelayDatagram = struct { peer: protocol.StunAddress, payload: []const u8 };
pub const TurnRelayIo = struct {
    context: *anyopaque,
    send_fn: *const fn (*anyopaque, []const u8) TurnRelayTransportError!void,
    pub fn send(self: TurnRelayIo, bytes: []const u8) TurnRelayTransportError!void {
        return self.send_fn(self.context, bytes);
    }
};

pub const TurnRelayTransport = struct {
    permissions: *permissions.TurnPermissions,
    channels: *channels.TurnChannels,
    io: TurnRelayIo,

    pub fn send_channel(self: *TurnRelayTransport, number: u16, payload: []const u8, output: []u8) TurnRelayTransportError!void {
        const frame = try self.channels.encode(.{ .number = number, .payload = payload }, output);
        try self.io.send(frame);
    }
    pub fn receive_channel(self: *TurnRelayTransport, input: []const u8) TurnRelayTransportError!TurnRelayDatagram {
        const data = try self.channels.decode(input);
        const binding = self.channels.binding(data.number) orelse return error.UnknownChannel;
        return .{ .peer = binding.peer, .payload = data.payload };
    }
    pub fn authorize_peer(self: *TurnRelayTransport, peer: protocol.StunAddress, now_ns: core.TimeNs) TurnRelayTransportError!void {
        if (!self.permissions.authorized(peer, now_ns)) return error.UnauthorizedPeer;
    }
};

test "TURN relay transport adapts authorized channel data without altering frames" {
    const Fixture = struct {
        bytes: []const u8 = "",
        fn send(context: *anyopaque, bytes: []const u8) TurnRelayTransportError!void {
            @as(*@This(), @ptrCast(@alignCast(context))).bytes = bytes;
        }
    };
    var permission_table = try permissions.TurnPermissions.init(@import("std").testing.allocator, .{ .maximum_permissions = 1, .lifetime_ns = 10 });
    defer permission_table.deinit();
    var channel_registry = try channels.TurnChannels.init(@import("std").testing.allocator, .{ .maximum_channels = 1 });
    defer channel_registry.deinit();
    const peer = protocol.StunAddress{ .ipv4 = .{ .octets = .{ 1, 2, 3, 4 }, .port = 9 } };
    _ = try permission_table.authorize(peer, 0);
    try channel_registry.bind(.{ .number = channels.turn_channel_min, .peer = peer });
    var fixture = Fixture{};
    var adapter = TurnRelayTransport{ .permissions = &permission_table, .channels = &channel_registry, .io = .{ .context = &fixture, .send_fn = Fixture.send } };
    var output: [7]u8 = undefined;
    try adapter.send_channel(channels.turn_channel_min, "abc", output[0..]);
    try @import("std").testing.expectEqualStrings(output[0..7], fixture.bytes);
    try @import("std").testing.expectEqual(peer, (try adapter.receive_channel(fixture.bytes)).peer);
    try adapter.authorize_peer(peer, 1);
    try @import("std").testing.expectError(error.UnauthorizedPeer, adapter.authorize_peer(peer, 10));
}
