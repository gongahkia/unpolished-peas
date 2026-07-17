const capability = @import("capability_negotiation.zig");

pub const SecurityComponentError = error{ ReplayRequiresEncryption, RotationRequiresEncryption, AuthenticationDowngrade, NegotiatedSecurityMismatch };

pub const SecurityComponents = struct {
    authentication: capability.SecurityCapability = .none,
    authenticated_encryption: bool = false,
    replay_protection: bool = false,
    key_rotation: bool = false,
};

pub fn validate_security_components(components: SecurityComponents) SecurityComponentError!void {
    if (components.replay_protection and !components.authenticated_encryption) return error.ReplayRequiresEncryption;
    if (components.key_rotation and !components.authenticated_encryption) return error.RotationRequiresEncryption;
}

pub fn validate_negotiated_security(components: SecurityComponents, negotiated: capability.SecurityCapability) SecurityComponentError!void {
    try validate_security_components(components);
    if (components.authentication == negotiated) return;
    if (components.authentication != .none and negotiated == .none) return error.AuthenticationDowngrade;
    return error.NegotiatedSecurityMismatch;
}

test "security components permit deliberate plain and independently authenticated modes" {
    try validate_security_components(.{});
    try validate_security_components(.{ .authentication = .psk });
    try validate_security_components(.{ .authentication = .public_key, .authenticated_encryption = true, .replay_protection = true, .key_rotation = true });
    try validate_security_components(.{ .authenticated_encryption = true });
    try validate_negotiated_security(.{ .authentication = .psk }, .psk);
}

test "security components reject dependent controls without AEAD and authentication downgrade" {
    try @import("std").testing.expectError(error.ReplayRequiresEncryption, validate_security_components(.{ .replay_protection = true }));
    try @import("std").testing.expectError(error.RotationRequiresEncryption, validate_security_components(.{ .key_rotation = true }));
    try @import("std").testing.expectError(error.AuthenticationDowngrade, validate_negotiated_security(.{ .authentication = .public_key }, .none));
    try @import("std").testing.expectError(error.NegotiatedSecurityMismatch, validate_negotiated_security(.{}, .psk));
}
