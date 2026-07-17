const core = @import("minna-san-core");
const envelope = @import("wire_envelope.zig");
const packet_envelope = @import("packet_envelope.zig");
const capability_negotiation = @import("capability_negotiation.zig");

pub const WireVersion = envelope.WireVersion;
pub const ExtensionRange = envelope.ExtensionRange;
pub const WireEnvelope = envelope.WireEnvelope;
pub const CompatibilityError = envelope.CompatibilityError;
pub const v1_version = envelope.v1_version;
pub const extension_range = envelope.extension_range;
pub const validate_version = envelope.validate_version;
pub const validate_extension = envelope.validate_extension;
pub const validate_envelope = envelope.validate_envelope;
pub const packet_header_bytes = packet_envelope.packet_header_bytes;
pub const max_packet_payload_bytes = packet_envelope.max_packet_payload_bytes;
pub const PacketEnvelopeError = packet_envelope.PacketEnvelopeError;
pub const encode_packet = packet_envelope.encode_packet;
pub const decode_packet = packet_envelope.decode_packet;
pub const TransportCapability = capability_negotiation.TransportCapability;
pub const ChannelCapability = capability_negotiation.ChannelCapability;
pub const SecurityCapability = capability_negotiation.SecurityCapability;
pub const CompressionCapability = capability_negotiation.CompressionCapability;
pub const CapabilityOffer = capability_negotiation.CapabilityOffer;
pub const NegotiatedCapabilities = capability_negotiation.NegotiatedCapabilities;
pub const CapabilityNegotiationError = capability_negotiation.CapabilityNegotiationError;
pub const negotiate_capabilities = capability_negotiation.negotiate_capabilities;
pub const package_name = "protocol";

comptime {
    _ = core.package_name;
}

test "protocol package boundary" {
    try @import("std").testing.expectEqualStrings("protocol", package_name);
}

test {
    _ = @import("wire_envelope.zig");
    _ = @import("packet_envelope.zig");
    _ = @import("capability_negotiation.zig");
}
