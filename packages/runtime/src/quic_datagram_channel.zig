const std = @import("std");
const core = @import("minna-san-core");
const delivery = @import("channel_delivery.zig");

pub const QuicDatagramFallback = enum(u8) {
    reject,
    stream,
};

pub const QuicDatagramSendStatus = enum(u8) {
    sent,
    congestion_blocked,
    discarded,
};

pub const QuicDatagramSendOutcome = enum {
    sent,
    congestion_blocked,
    discarded,
    fallback_to_stream,
};

pub const QuicDatagramSendOutput = extern struct {
    status: u8 = @intFromEnum(QuicDatagramSendStatus.sent),
    reserved: [7]u8 = [_]u8{0} ** 7,

    fn decode(self: QuicDatagramSendOutput) ?QuicDatagramSendOutcome {
        if (!std.mem.allEqual(u8, self.reserved[0..], 0)) return null;
        return switch (std.meta.intToEnum(QuicDatagramSendStatus, self.status) catch return null) {
            .sent => .sent,
            .congestion_blocked => .congestion_blocked,
            .discarded => .discarded,
        };
    }
};

pub const QuicDatagramProviderVTable = extern struct {
    send: *const fn (?*anyopaque, [*]const u8, usize, *QuicDatagramSendOutput) callconv(.c) c_int,
};

pub const QuicDatagramChannelConfig = struct {
    descriptor: delivery.ChannelDescriptor,
    provider_capabilities: core.ProviderCapabilityDescriptor,
    peer_maximum_datagram_bytes: ?usize = null,
    fallback: QuicDatagramFallback = .reject,

    pub fn validate(self: QuicDatagramChannelConfig) error{ InvalidConfiguration, ProviderCapabilityUnsupported }!void {
        try self.descriptor.validate();
        try self.provider_capabilities.validate();
        if (self.descriptor.delivery != .datagram or !self.provider_capabilities.supports(.{ .transport_bits = core.transport_capability_bit(.quic), .delivery_bits = core.delivery_capability_bit(.datagrams) })) return error.ProviderCapabilityUnsupported;
        if (self.peer_maximum_datagram_bytes) |limit| if (limit == 0) return error.InvalidConfiguration;
    }
};

pub const QuicDatagramChannelError = delivery.ChannelDeliveryError || core.ProviderCapabilityDescriptorError || error{ InvalidConfiguration, ProviderCapabilityUnsupported, PeerDatagramUnsupported, ProviderFailed };

pub const QuicDatagramChannel = struct {
    config: QuicDatagramChannelConfig,
    context: ?*anyopaque,
    vtable: QuicDatagramProviderVTable,

    pub fn init(config: QuicDatagramChannelConfig, context: ?*anyopaque, vtable: QuicDatagramProviderVTable) QuicDatagramChannelError!QuicDatagramChannel {
        try config.validate();
        return .{ .config = config, .context = context, .vtable = vtable };
    }

    pub fn send(self: *const QuicDatagramChannel, payload: []const u8) QuicDatagramChannelError!QuicDatagramSendOutcome {
        try self.config.descriptor.validate_payload(payload.len);
        const peer_limit = self.config.peer_maximum_datagram_bytes orelse return switch (self.config.fallback) {
            .reject => error.PeerDatagramUnsupported,
            .stream => .fallback_to_stream,
        };
        if (payload.len > peer_limit) return error.PayloadTooLarge;
        var output = QuicDatagramSendOutput{};
        if (self.vtable.send(self.context, payload.ptr, payload.len, &output) != @intFromEnum(core.CResult.ok)) return error.ProviderFailed;
        return output.decode() orelse error.ProviderFailed;
    }
};

test "QUIC datagram channels reject absent peer capability and report bounded send outcomes" {
    const FakeProvider = struct {
        calls: usize = 0,
        status: QuicDatagramSendStatus = .sent,

        fn send(context: ?*anyopaque, payload: [*]const u8, payload_len: usize, output: *QuicDatagramSendOutput) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            if (!std.mem.eql(u8, payload[0..payload_len], "ping")) return @intFromEnum(core.CResult.invalid_argument);
            output.* = .{ .status = @intFromEnum(self.status) };
            return @intFromEnum(core.CResult.ok);
        }
    };

    const descriptor = delivery.ChannelDescriptor{ .delivery = .datagram, .maximum_payload_bytes = 8 };
    const capabilities = core.ProviderCapabilityDescriptor{ .transport_bits = core.transport_capability_bit(.quic), .delivery_bits = core.delivery_capability_bit(.datagrams) };
    var fake = FakeProvider{};
    var channel = try QuicDatagramChannel.init(.{ .descriptor = descriptor, .provider_capabilities = capabilities, .peer_maximum_datagram_bytes = 4 }, &fake, .{ .send = FakeProvider.send });
    try std.testing.expectEqual(QuicDatagramSendOutcome.sent, try channel.send("ping"));
    fake.status = .congestion_blocked;
    try std.testing.expectEqual(QuicDatagramSendOutcome.congestion_blocked, try channel.send("ping"));
    try std.testing.expectError(error.PayloadTooLarge, channel.send("oversized"));
    const rejected = try QuicDatagramChannel.init(.{ .descriptor = descriptor, .provider_capabilities = capabilities }, &fake, .{ .send = FakeProvider.send });
    try std.testing.expectError(error.PeerDatagramUnsupported, rejected.send("ping"));
    const fallback = try QuicDatagramChannel.init(.{ .descriptor = descriptor, .provider_capabilities = capabilities, .fallback = .stream }, &fake, .{ .send = FakeProvider.send });
    try std.testing.expectEqual(QuicDatagramSendOutcome.fallback_to_stream, try fallback.send("ping"));
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    try std.testing.expectError(error.ProviderCapabilityUnsupported, QuicDatagramChannel.init(.{ .descriptor = descriptor, .provider_capabilities = .{ .transport_bits = core.transport_capability_bit(.quic) } }, &fake, .{ .send = FakeProvider.send }));
}
