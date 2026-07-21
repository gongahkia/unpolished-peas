const taxonomy = @import("error_taxonomy.zig");
const ownership = @import("ownership.zig");
const clock = @import("clock.zig");
const capability = @import("capability.zig");
const platform_config = @import("platform_config.zig");

pub const ErrorClass = taxonomy.ErrorClass;
pub const CResult = taxonomy.CResult;
pub const Retryability = taxonomy.Retryability;
pub const OperatorCategory = taxonomy.OperatorCategory;
pub const ErrorDisposition = taxonomy.ErrorDisposition;
pub const ZigError = taxonomy.ZigError;
pub const all_errors = taxonomy.all_errors;
pub const class_for_error = taxonomy.class_for_error;
pub const error_for_class = taxonomy.error_for_class;
pub const c_result_for_class = taxonomy.c_result_for_class;
pub const class_for_c_result = taxonomy.class_for_c_result;
pub const c_result_for_error = taxonomy.c_result_for_error;
pub const error_for_c_result = taxonomy.error_for_c_result;
pub const disposition_for_class = taxonomy.disposition_for_class;
pub const disposition_for_c_result = taxonomy.disposition_for_c_result;
pub const disposition_for_any_error = taxonomy.disposition_for_any_error;
pub const c_result_from_code = taxonomy.c_result_from_code;
pub const Ownership = ownership.Ownership;
pub const BufferError = ownership.BufferError;
pub const BorrowedBuffer = ownership.BorrowedBuffer;
pub const OwnedBuffer = ownership.OwnedBuffer;
pub const RetainedBuffer = ownership.RetainedBuffer;
pub const TransferError = ownership.TransferError;
pub const TransferredBuffer = ownership.TransferredBuffer;
pub const TimeNs = clock.TimeNs;
pub const ClockError = clock.ClockError;
pub const Clock = clock.Clock;
pub const CheckedClock = clock.CheckedClock;
pub const ManualClock = clock.ManualClock;
pub const Capability = capability.Capability;
pub const CapabilityError = capability.CapabilityError;
pub const CapabilityConfig = capability.CapabilityConfig;
pub const provider_capability_descriptor_version = capability.provider_capability_descriptor_version;
pub const TransportCapability = capability.TransportCapability;
pub const SecurityCapability = capability.SecurityCapability;
pub const CipherCapability = capability.CipherCapability;
pub const DeliveryCapability = capability.DeliveryCapability;
pub const ProtocolCapability = capability.ProtocolCapability;
pub const transport_capability_bit = capability.transport_capability_bit;
pub const security_capability_bit = capability.security_capability_bit;
pub const cipher_capability_bit = capability.cipher_capability_bit;
pub const delivery_capability_bit = capability.delivery_capability_bit;
pub const protocol_capability_bit = capability.protocol_capability_bit;
pub const ProviderCapabilityDescriptorError = capability.ProviderCapabilityDescriptorError;
pub const ProviderCapabilityRequirement = capability.ProviderCapabilityRequirement;
pub const ProviderCapabilityDescriptor = capability.ProviderCapabilityDescriptor;
pub const configuration_version = platform_config.configuration_version;
pub const max_provider_capacity = platform_config.max_provider_capacity;
pub const max_service_capacity = platform_config.max_service_capacity;
pub const max_session_capacity = platform_config.max_session_capacity;
pub const max_channel_capacity = platform_config.max_channel_capacity;
pub const max_listener_capacity = platform_config.max_listener_capacity;
pub const max_event_capacity = platform_config.max_event_capacity;
pub const max_poll_work_budget = platform_config.max_poll_work_budget;
pub const PlatformLimits = platform_config.PlatformLimits;
pub const PlatformConfig = platform_config.PlatformConfig;
pub const package_name = "core";

test "core package boundary" {
    try @import("std").testing.expectEqualStrings("core", package_name);
}

test {
    _ = @import("error_taxonomy.zig");
    _ = @import("ownership.zig");
    _ = @import("clock.zig");
    _ = @import("capability.zig");
    _ = @import("platform_config.zig");
}
