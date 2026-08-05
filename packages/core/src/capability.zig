const std = @import("std");

pub const Capability = enum {
    transport,
    packet_protection,
    topology,
    state_replication,
    capture,
};

pub const CapabilityError = error{UnsupportedCapabilityCombination};

pub const provider_capability_descriptor_version: u32 = 2;

pub const TransportCapability = enum(u5) {
    udp,
    tcp,
    relay,
    quic,
};

pub const SecurityCapability = enum(u5) {
    tls,
    packet_protection,
};

pub const CipherCapability = enum(u5) {
    aes_256_gcm,
    chacha20_poly1305,
};

pub const DeliveryCapability = enum(u5) {
    streams,
    datagrams,
};

pub const ProtocolCapability = enum(u5) {
    http1,
    http2,
    http3,
    websocket,
    stun,
    turn,
};

pub fn transport_capability_bit(capability: TransportCapability) u32 {
    return @as(u32, 1) << @intFromEnum(capability);
}

pub fn security_capability_bit(capability: SecurityCapability) u32 {
    return @as(u32, 1) << @intFromEnum(capability);
}

pub fn cipher_capability_bit(capability: CipherCapability) u32 {
    return @as(u32, 1) << @intFromEnum(capability);
}

pub fn delivery_capability_bit(capability: DeliveryCapability) u32 {
    return @as(u32, 1) << @intFromEnum(capability);
}

pub fn protocol_capability_bit(capability: ProtocolCapability) u32 {
    return @as(u32, 1) << @intFromEnum(capability);
}

pub const transport_capability_mask: u32 = transport_capability_bit(.udp) | transport_capability_bit(.tcp) | transport_capability_bit(.relay) | transport_capability_bit(.quic);
pub const security_capability_mask: u32 = security_capability_bit(.tls) | security_capability_bit(.packet_protection);
pub const cipher_capability_mask: u32 = cipher_capability_bit(.aes_256_gcm) | cipher_capability_bit(.chacha20_poly1305);
pub const delivery_capability_mask: u32 = delivery_capability_bit(.streams) | delivery_capability_bit(.datagrams);
pub const protocol_capability_mask: u32 = protocol_capability_bit(.http1) | protocol_capability_bit(.http2) | protocol_capability_bit(.http3) | protocol_capability_bit(.websocket) | protocol_capability_bit(.stun) | protocol_capability_bit(.turn);

pub const ProviderCapabilityDescriptorError = error{ InvalidProviderCapabilityVersion, InvalidProviderCapabilityBits };

pub const ProviderCapabilityRequirement = extern struct {
    transport_bits: u32 = 0,
    security_bits: u32 = 0,
    cipher_bits: u32 = 0,
    delivery_bits: u32 = 0,
    protocol_bits: u32 = 0,

    pub fn validate(self: ProviderCapabilityRequirement) ProviderCapabilityDescriptorError!void {
        if (self.transport_bits & ~transport_capability_mask != 0 or self.security_bits & ~security_capability_mask != 0 or self.cipher_bits & ~cipher_capability_mask != 0 or self.delivery_bits & ~delivery_capability_mask != 0 or self.protocol_bits & ~protocol_capability_mask != 0) return error.InvalidProviderCapabilityBits;
    }
};

pub const ProviderCapabilityDescriptor = extern struct {
    version: u32 = provider_capability_descriptor_version,
    transport_bits: u32 = 0,
    security_bits: u32 = 0,
    cipher_bits: u32 = 0,
    delivery_bits: u32 = 0,
    protocol_bits: u32 = 0,

    pub fn validate(self: ProviderCapabilityDescriptor) ProviderCapabilityDescriptorError!void {
        if (self.version != provider_capability_descriptor_version) return error.InvalidProviderCapabilityVersion;
        try (ProviderCapabilityRequirement{ .transport_bits = self.transport_bits, .security_bits = self.security_bits, .cipher_bits = self.cipher_bits, .delivery_bits = self.delivery_bits, .protocol_bits = self.protocol_bits }).validate();
    }

    pub fn supports(self: ProviderCapabilityDescriptor, required: ProviderCapabilityRequirement) bool {
        return (self.transport_bits & required.transport_bits) == required.transport_bits and (self.security_bits & required.security_bits) == required.security_bits and (self.cipher_bits & required.cipher_bits) == required.cipher_bits and (self.delivery_bits & required.delivery_bits) == required.delivery_bits and (self.protocol_bits & required.protocol_bits) == required.protocol_bits;
    }
};

pub const CapabilityConfig = struct {
    transport: bool = false,
    packet_protection: bool = false,
    topology: bool = false,
    state_replication: bool = false,
    capture: bool = false,

    pub fn enable(self: *CapabilityConfig, capability: Capability) void {
        switch (capability) {
            .transport => self.transport = true,
            .packet_protection => self.packet_protection = true,
            .topology => self.topology = true,
            .state_replication => self.state_replication = true,
            .capture => self.capture = true,
        }
    }

    pub fn is_enabled(self: CapabilityConfig, capability: Capability) bool {
        return switch (capability) {
            .transport => self.transport,
            .packet_protection => self.packet_protection,
            .topology => self.topology,
            .state_replication => self.state_replication,
            .capture => self.capture,
        };
    }

    pub fn validate(self: CapabilityConfig) CapabilityError!void {
        if (!self.transport and (self.packet_protection or self.topology or self.state_replication or self.capture)) {
            return error.UnsupportedCapabilityCombination;
        }
    }
};

test "capabilities are opt-in and valid with their transport prerequisite" {
    var config = CapabilityConfig{};
    try config.validate();
    inline for (std.meta.fields(Capability)) |field| {
        try std.testing.expect(!config.is_enabled(@enumFromInt(field.value)));
    }
    config.enable(.transport);
    config.enable(.packet_protection);
    config.enable(.topology);
    config.enable(.state_replication);
    config.enable(.capture);
    try config.validate();
}

test "transport-dependent capability combinations fail deterministically" {
    inline for ([_]Capability{ .packet_protection, .topology, .state_replication, .capture }) |capability| {
        var config = CapabilityConfig{};
        config.enable(capability);
        try std.testing.expectError(error.UnsupportedCapabilityCombination, config.validate());
    }
}

test "versioned provider descriptors reject unknown bits and satisfy uniform requirements" {
    const descriptor = ProviderCapabilityDescriptor{
        .transport_bits = transport_capability_bit(.quic),
        .security_bits = security_capability_bit(.tls),
        .cipher_bits = cipher_capability_bit(.aes_256_gcm),
        .delivery_bits = delivery_capability_bit(.streams) | delivery_capability_bit(.datagrams),
        .protocol_bits = protocol_capability_bit(.http3),
    };
    try descriptor.validate();
    try std.testing.expect(descriptor.supports(.{ .transport_bits = transport_capability_bit(.quic), .security_bits = security_capability_bit(.tls), .cipher_bits = cipher_capability_bit(.aes_256_gcm), .delivery_bits = delivery_capability_bit(.streams), .protocol_bits = protocol_capability_bit(.http3) }));
    try std.testing.expect(!descriptor.supports(.{ .protocol_bits = protocol_capability_bit(.websocket) }));
    try std.testing.expectError(error.InvalidProviderCapabilityBits, (ProviderCapabilityRequirement{ .transport_bits = 1 << 31 }).validate());
    try std.testing.expectError(error.InvalidProviderCapabilityBits, (ProviderCapabilityRequirement{ .cipher_bits = 1 << 31 }).validate());
    try std.testing.expectError(error.InvalidProviderCapabilityVersion, (ProviderCapabilityDescriptor{ .version = provider_capability_descriptor_version + 1 }).validate());
}
