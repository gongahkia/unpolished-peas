const std = @import("std");
const core = @import("minna-san-core");
const protocol = @import("minna-san-protocol");

pub const ChannelDelivery = protocol.ChannelCapability;
pub const ChannelOrdering = enum(u8) { unordered, ordered, sequenced };
pub const ChannelFraming = enum(u8) { messages, bytes };
pub const ChannelTransport = enum(u8) { stream, datagram };
pub const ChannelReplaySafety = enum(u8) { replay_safe, replay_sensitive };
pub const ChannelBackpressure = enum(u8) { writable, queue_full, transport_blocked, closed };
pub const ChannelDeliveryError = core.ProviderCapabilityDescriptorError || error{ InvalidDescriptor, PayloadTooLarge, UnsupportedDelivery };

pub const ChannelSemantics = struct {
    reliable: bool,
    ordering: ChannelOrdering,
    framing: ChannelFraming,
};

pub const ChannelDescriptor = struct {
    delivery: ChannelDelivery,
    priority: u8 = 128,
    maximum_payload_bytes: usize,
    maximum_in_flight: usize = 1,
    replay_safety: ChannelReplaySafety = .replay_safe,

    pub fn validate(self: ChannelDescriptor) ChannelDeliveryError!void {
        if (self.maximum_payload_bytes == 0 or self.maximum_in_flight == 0) return error.InvalidDescriptor;
    }

    pub fn semantics(self: ChannelDescriptor) ChannelSemantics {
        return switch (self.delivery) {
            .reliable => .{ .reliable = true, .ordering = .unordered, .framing = .messages },
            .ordered => .{ .reliable = true, .ordering = .ordered, .framing = .messages },
            .sequenced => .{ .reliable = false, .ordering = .sequenced, .framing = .messages },
            .stream => .{ .reliable = true, .ordering = .ordered, .framing = .bytes },
            .datagram => .{ .reliable = false, .ordering = .unordered, .framing = .messages },
        };
    }

    pub fn transport(self: ChannelDescriptor) ChannelTransport {
        return switch (self.delivery) {
            .reliable, .ordered, .stream => .stream,
            .sequenced, .datagram => .datagram,
        };
    }

    pub fn required_capabilities(self: ChannelDescriptor) core.ProviderCapabilityRequirement {
        return switch (self.transport()) {
            .stream => .{ .delivery_bits = core.delivery_capability_bit(.streams) },
            .datagram => .{ .delivery_bits = core.delivery_capability_bit(.datagrams) },
        };
    }

    pub fn validate_payload(self: ChannelDescriptor, payload_len: usize) ChannelDeliveryError!void {
        try self.validate();
        if (payload_len > self.maximum_payload_bytes) return error.PayloadTooLarge;
    }
};

pub const ChannelBinding = struct {
    provider_index: usize,
    transport: ChannelTransport,
    semantics: ChannelSemantics,
};

pub fn provider_behavior(descriptor: ChannelDescriptor, capabilities: core.ProviderCapabilityDescriptor) ChannelDeliveryError!?ChannelTransport {
    try descriptor.validate();
    try capabilities.validate();
    if (!capabilities.supports(descriptor.required_capabilities())) return null;
    return descriptor.transport();
}

pub const ChannelCapabilityMatrix = struct {
    providers: []const core.ProviderCapabilityDescriptor,

    pub fn select(self: ChannelCapabilityMatrix, descriptor: ChannelDescriptor) ChannelDeliveryError!ChannelBinding {
        for (self.providers, 0..) |capabilities, provider_index| {
            const transport = try provider_behavior(descriptor, capabilities) orelse continue;
            return .{ .provider_index = provider_index, .transport = transport, .semantics = descriptor.semantics() };
        }
        return error.UnsupportedDelivery;
    }
};

test "channel capability matrix maps every delivery request to provider behavior" {
    const providers = [_]core.ProviderCapabilityDescriptor{
        .{ .delivery_bits = core.delivery_capability_bit(.streams) },
        .{ .delivery_bits = core.delivery_capability_bit(.datagrams) },
    };
    const matrix = ChannelCapabilityMatrix{ .providers = &providers };
    const deliveries = [_]ChannelDelivery{ .reliable, .ordered, .sequenced, .stream, .datagram };
    for (deliveries) |delivery| {
        const descriptor = ChannelDescriptor{ .delivery = delivery, .maximum_payload_bytes = 32, .maximum_in_flight = 2 };
        const binding = try matrix.select(descriptor);
        try std.testing.expectEqual(descriptor.transport(), binding.transport);
        try std.testing.expectEqual(if (binding.transport == .stream) @as(usize, 0) else @as(usize, 1), binding.provider_index);
        try std.testing.expectEqual(descriptor.semantics(), binding.semantics);
    }
}

test "channel descriptors enforce payload bounds and unavailable delivery behavior" {
    const streams_only = [_]core.ProviderCapabilityDescriptor{.{ .delivery_bits = core.delivery_capability_bit(.streams) }};
    const matrix = ChannelCapabilityMatrix{ .providers = &streams_only };
    const ordered = ChannelDescriptor{ .delivery = .ordered, .maximum_payload_bytes = 2 };
    try std.testing.expectEqual(ChannelTransport.stream, (try matrix.select(ordered)).transport);
    try ordered.validate_payload(2);
    try std.testing.expectError(error.PayloadTooLarge, ordered.validate_payload(3));
    try std.testing.expectError(error.UnsupportedDelivery, matrix.select(.{ .delivery = .datagram, .maximum_payload_bytes = 1 }));
    try std.testing.expectError(error.InvalidDescriptor, matrix.select(.{ .delivery = .stream, .maximum_payload_bytes = 0 }));
}
