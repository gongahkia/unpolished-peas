const core = @import("minna-san-core");
const envelope = @import("wire_envelope.zig");

pub const PreReleasePhase = enum(u8) { evolving, frozen };
pub const PreReleaseVersionComponent = enum(u8) { platform_config, provider_capabilities, wire_major, wire_minor };

pub const PreReleaseVersionOffer = struct {
    platform_config_version: u32,
    provider_capability_version: u32,
    wire_version: envelope.WireVersion,

    pub fn from(platform_config: core.PlatformConfig, provider_capabilities: core.ProviderCapabilityDescriptor, wire_version: envelope.WireVersion) PreReleaseVersionOffer {
        return .{ .platform_config_version = platform_config.version, .provider_capability_version = provider_capabilities.version, .wire_version = wire_version };
    }
};

pub const PreReleaseCompatibilityError = struct {
    component: PreReleaseVersionComponent,
    local_version: u32,
    remote_version: u32,
};

pub const PreReleaseCompatibility = union(enum) {
    compatible: PreReleaseVersionOffer,
    incompatible: PreReleaseCompatibilityError,
};

pub const PreReleaseCompatibilityPolicy = struct {
    phase: PreReleasePhase = .evolving,

    pub fn negotiate(self: PreReleaseCompatibilityPolicy, local: PreReleaseVersionOffer, remote: PreReleaseVersionOffer) PreReleaseCompatibility {
        if (local.platform_config_version != remote.platform_config_version) return .{ .incompatible = .{ .component = .platform_config, .local_version = local.platform_config_version, .remote_version = remote.platform_config_version } };
        if (local.provider_capability_version != remote.provider_capability_version) return .{ .incompatible = .{ .component = .provider_capabilities, .local_version = local.provider_capability_version, .remote_version = remote.provider_capability_version } };
        if (local.wire_version.major != remote.wire_version.major) return .{ .incompatible = .{ .component = .wire_major, .local_version = local.wire_version.major, .remote_version = remote.wire_version.major } };
        if (self.phase == .frozen and local.wire_version.minor != remote.wire_version.minor) return .{ .incompatible = .{ .component = .wire_minor, .local_version = local.wire_version.minor, .remote_version = remote.wire_version.minor } };
        return .{ .compatible = .{
            .platform_config_version = local.platform_config_version,
            .provider_capability_version = local.provider_capability_version,
            .wire_version = .{ .major = local.wire_version.major, .minor = @min(local.wire_version.minor, remote.wire_version.minor) },
        } };
    }
};

pub fn default_pre_release_version_offer() PreReleaseVersionOffer {
    return .{
        .platform_config_version = core.configuration_version,
        .provider_capability_version = core.provider_capability_descriptor_version,
        .wire_version = envelope.v1_version,
    };
}

pub fn validate_negotiated_envelope(value: envelope.WireEnvelope, negotiated: PreReleaseVersionOffer) envelope.CompatibilityError!void {
    if (value.version.major != negotiated.wire_version.major or value.version.minor != negotiated.wire_version.minor) return error.VersionMismatch;
    try envelope.validate_extension(value.extension_id);
}

test "pre-release compatibility reports structured platform provider and wire failures" {
    const local = default_pre_release_version_offer();
    const policy = PreReleaseCompatibilityPolicy{};
    var remote = local;
    remote.platform_config_version += 1;
    try @import("std").testing.expectEqual(PreReleaseCompatibilityError{ .component = .platform_config, .local_version = local.platform_config_version, .remote_version = remote.platform_config_version }, policy.negotiate(local, remote).incompatible);
    remote = local;
    remote.provider_capability_version += 1;
    try @import("std").testing.expectEqual(PreReleaseCompatibilityError{ .component = .provider_capabilities, .local_version = local.provider_capability_version, .remote_version = remote.provider_capability_version }, policy.negotiate(local, remote).incompatible);
    remote = local;
    remote.wire_version.major += 1;
    try @import("std").testing.expectEqual(PreReleaseCompatibilityError{ .component = .wire_major, .local_version = local.wire_version.major, .remote_version = remote.wire_version.major }, policy.negotiate(local, remote).incompatible);
}

test "evolving peers negotiate a common wire minor until the version freeze" {
    var local = default_pre_release_version_offer();
    local.wire_version.minor = 2;
    var remote = local;
    remote.wire_version.minor = 1;
    const evolving_policy = PreReleaseCompatibilityPolicy{};
    const evolving = evolving_policy.negotiate(local, remote).compatible;
    try @import("std").testing.expectEqual(@as(u16, 1), evolving.wire_version.minor);
    const frozen_policy = PreReleaseCompatibilityPolicy{ .phase = .frozen };
    const frozen = frozen_policy.negotiate(local, remote).incompatible;
    try @import("std").testing.expectEqual(PreReleaseVersionComponent.wire_minor, frozen.component);
    try validate_negotiated_envelope(.{ .version = evolving.wire_version, .extension_id = 0, .payload = "" }, evolving);
    try @import("std").testing.expectError(error.VersionMismatch, validate_negotiated_envelope(.{ .version = local.wire_version, .extension_id = 0, .payload = "" }, evolving));
}
