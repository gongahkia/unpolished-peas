const std = @import("std");

pub const TransportCapability = enum(u8) { udp, tcp };
pub const ChannelCapability = enum(u8) { unreliable, reliable };
pub const SecurityCapability = enum(u8) { none, psk, public_key };
pub const CompressionCapability = enum(u8) { none, lz4 };
pub const max_compression_dictionary_ids: usize = 16;
pub const CompressionDictionaryOfferError = error{ InvalidIdentifier, DuplicateIdentifier, CapacityExceeded };

pub const CompressionDictionaryOffer = struct {
    identifiers: [max_compression_dictionary_ids]u32 = undefined,
    count: usize = 0,

    pub fn insert(self: *CompressionDictionaryOffer, identifier: u32) CompressionDictionaryOfferError!void {
        if (identifier == 0) return error.InvalidIdentifier;
        for (self.identifiers[0..self.count]) |existing| if (existing == identifier) return error.DuplicateIdentifier;
        if (self.count == max_compression_dictionary_ids) return error.CapacityExceeded;
        self.identifiers[self.count] = identifier;
        self.count += 1;
    }

    pub fn contains(self: CompressionDictionaryOffer, identifier: u32) bool {
        for (self.identifiers[0..self.count]) |existing| if (existing == identifier) return true;
        return false;
    }

    fn is_valid(self: CompressionDictionaryOffer) bool {
        if (self.count > max_compression_dictionary_ids) return false;
        for (self.identifiers[0..self.count], 0..) |identifier, index| {
            if (identifier == 0) return false;
            for (self.identifiers[0..index]) |previous| if (previous == identifier) return false;
        }
        return true;
    }
};

pub const CapabilityOffer = struct {
    transports: u8,
    channels: u8,
    security: u8,
    compression: u8,
    compression_dictionaries: CompressionDictionaryOffer = .{},
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
    compression_dictionary_id: ?u32,
    extensions: u64,
};

pub const CapabilityNegotiationError = error{ NoCommonTransport, NoCommonChannel, NoCommonSecurity, NoCommonCompression, InvalidDictionaryOffer };

pub fn negotiate_capabilities(local: CapabilityOffer, remote: CapabilityOffer) CapabilityNegotiationError!NegotiatedCapabilities {
    const compression = select(CompressionCapability, local.compression & remote.compression) orelse return error.NoCommonCompression;
    return .{
        .transport = select(TransportCapability, local.transports & remote.transports) orelse return error.NoCommonTransport,
        .channel = select(ChannelCapability, local.channels & remote.channels) orelse return error.NoCommonChannel,
        .security = select(SecurityCapability, local.security & remote.security) orelse return error.NoCommonSecurity,
        .compression = compression,
        .compression_dictionary_id = if (compression == .none) null else try select_dictionary(local.compression_dictionaries, remote.compression_dictionaries),
        .extensions = local.extensions & remote.extensions,
    };
}

fn select_dictionary(local: CompressionDictionaryOffer, remote: CompressionDictionaryOffer) CapabilityNegotiationError!?u32 {
    if (!local.is_valid() or !remote.is_valid()) return error.InvalidDictionaryOffer;
    for (local.identifiers[0..local.count]) |identifier| if (remote.contains(identifier)) return identifier;
    return null;
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
    try std.testing.expect(result.compression_dictionary_id == null);
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

test "compression dictionary offers negotiate deterministic bounded identifiers" {
    var local_dictionaries = CompressionDictionaryOffer{};
    try local_dictionaries.insert(7);
    try local_dictionaries.insert(9);
    var remote_dictionaries = CompressionDictionaryOffer{};
    try remote_dictionaries.insert(9);
    const offer = CapabilityOffer{
        .transports = bit(TransportCapability, .udp),
        .channels = bit(ChannelCapability, .unreliable),
        .security = bit(SecurityCapability, .none),
        .compression = bit(CompressionCapability, .lz4),
        .compression_dictionaries = local_dictionaries,
        .extensions = 0,
    };
    var remote = offer;
    remote.compression_dictionaries = remote_dictionaries;
    try std.testing.expectEqual(@as(?u32, 9), (try negotiate_capabilities(offer, remote)).compression_dictionary_id);
    try std.testing.expectError(error.DuplicateIdentifier, local_dictionaries.insert(7));
}
