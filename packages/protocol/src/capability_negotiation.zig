const std = @import("std");

pub const TransportCapability = enum(u8) { udp, tcp };
pub const ChannelCapability = enum(u8) { unreliable, reliable };
pub const SecurityCapability = enum(u8) { none, psk, public_key };
pub const CompressionCapability = enum(u8) { none, lz4 };

pub const CapabilityOffer = struct {
    transports: u8,
    channels: u8,
    security: u8,
    compression: u8,
    extensions: u64,

    pub fn supports_transport(self: CapabilityOffer, capability: TransportCapability) bool {
        return self.transports & bit(TransportCapability, capability) != 0;
    }
};

pub const NegotiatedCapabilities = struct {
    transport: TransportCapability,
    channel: ChannelCapability,
    security: SecurityCapability,
    compression: CompressionCapability,
    extensions: u64,
};

pub const CapabilityNegotiationError = error{ NoCommonTransport, NoCommonChannel, NoCommonSecurity, NoCommonCompression };

pub fn negotiate_capabilities(local: CapabilityOffer, remote: CapabilityOffer) CapabilityNegotiationError!NegotiatedCapabilities {
    return .{
        .transport = select(TransportCapability, local.transports & remote.transports) orelse return error.NoCommonTransport,
        .channel = select(ChannelCapability, local.channels & remote.channels) orelse return error.NoCommonChannel,
        .security = select(SecurityCapability, local.security & remote.security) orelse return error.NoCommonSecurity,
        .compression = select(CompressionCapability, local.compression & remote.compression) orelse return error.NoCommonCompression,
        .extensions = local.extensions & remote.extensions,
    };
}

fn bit(comptime T: type, value: T) u8 {
    return @as(u8, 1) << @as(u3, @intCast(@intFromEnum(value)));
}

fn select(comptime T: type, values: u8) ?T {
    inline for (std.meta.fields(T)) |field| {
        const value: T = @enumFromInt(field.value);
        if (values & bit(T, value) != 0) return value;
    }
    return null;
}

test "capability negotiation deterministically selects common capabilities" {
    const local = CapabilityOffer{
        .transports = bit(TransportCapability, .udp) | bit(TransportCapability, .tcp),
        .channels = bit(ChannelCapability, .unreliable) | bit(ChannelCapability, .reliable),
        .security = bit(SecurityCapability, .none) | bit(SecurityCapability, .psk),
        .compression = bit(CompressionCapability, .none) | bit(CompressionCapability, .lz4),
        .extensions = 0b101,
    };
    const remote = CapabilityOffer{
        .transports = bit(TransportCapability, .tcp),
        .channels = bit(ChannelCapability, .reliable),
        .security = bit(SecurityCapability, .psk),
        .compression = bit(CompressionCapability, .lz4),
        .extensions = 0b110,
    };
    const result = try negotiate_capabilities(local, remote);
    try std.testing.expectEqual(TransportCapability.tcp, result.transport);
    try std.testing.expectEqual(ChannelCapability.reliable, result.channel);
    try std.testing.expectEqual(SecurityCapability.psk, result.security);
    try std.testing.expectEqual(CompressionCapability.lz4, result.compression);
    try std.testing.expectEqual(@as(u64, 0b100), result.extensions);
}

test "capability negotiation rejects missing required capability classes" {
    const offer = CapabilityOffer{
        .transports = bit(TransportCapability, .udp),
        .channels = bit(ChannelCapability, .unreliable),
        .security = bit(SecurityCapability, .none),
        .compression = bit(CompressionCapability, .none),
        .extensions = 0,
    };
    var remote = offer;
    remote.transports = bit(TransportCapability, .tcp);
    try std.testing.expectError(error.NoCommonTransport, negotiate_capabilities(offer, remote));
}
