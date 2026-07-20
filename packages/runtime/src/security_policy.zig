const core = @import("minna-san-core");
const provider = @import("provider.zig");

pub const RuntimeSecurityEnvironment = enum(u8) { development, production };
pub const SecurityPolicyError = core.ProviderCapabilityDescriptorError || error{ PlaintextForbidden, TlsRequired, CredentialCallbackRequired, CipherSuiteRequired, CipherRequiresTls, CredentialRequiresTls, ProviderConstraintUnsatisfied, CredentialRejected };

pub const SecurityCredentialRequest = struct {
    provider_name: []const u8,
    capabilities: core.ProviderCapabilityDescriptor,
};

pub const SecurityCredentialCallback = *const fn (context: ?*anyopaque, request: SecurityCredentialRequest) SecurityPolicyError!void;

pub const RuntimeSecurityPolicy = struct {
    environment: RuntimeSecurityEnvironment = .development,
    prohibit_plaintext: bool = false,
    require_tls: bool = false,
    require_credentials: bool = false,
    required_cipher_bits: u32 = 0,
    required_provider_capabilities: core.ProviderCapabilityRequirement = .{},
    credential_context: ?*anyopaque = null,
    credential_callback: ?SecurityCredentialCallback = null,

    pub fn validate(self: RuntimeSecurityPolicy) SecurityPolicyError!void {
        try self.required_provider_capabilities.validate();
        try self.providerRequirements().validate();
        if (self.required_cipher_bits != 0 and !self.require_tls) return error.CipherRequiresTls;
        if (self.require_credentials and !self.require_tls) return error.CredentialRequiresTls;
        if (self.require_credentials and self.credential_callback == null) return error.CredentialCallbackRequired;
        if (self.environment == .production) {
            if (!self.prohibit_plaintext) return error.PlaintextForbidden;
            if (!self.require_tls) return error.TlsRequired;
            if (!self.require_credentials or self.credential_callback == null) return error.CredentialCallbackRequired;
            if (self.required_cipher_bits == 0) return error.CipherSuiteRequired;
        }
    }

    pub fn providerRequirements(self: RuntimeSecurityPolicy) core.ProviderCapabilityRequirement {
        var requirements = self.required_provider_capabilities;
        if (self.require_tls) requirements.security_bits |= core.security_capability_bit(.tls);
        requirements.cipher_bits |= self.required_cipher_bits;
        return requirements;
    }

    pub fn validateProviders(self: RuntimeSecurityPolicy, registry: *const provider.ProviderRegistry) SecurityPolicyError!void {
        try self.validate();
        const requirements = self.providerRequirements();
        if (!registry.supportsRequirements(requirements)) return error.ProviderConstraintUnsatisfied;
        if (!self.require_credentials) return;
        const callback = self.credential_callback orelse return error.CredentialCallbackRequired;
        for (registry.providers.items) |registered| {
            if (registered.state != .active or !registered.capabilities.supports(requirements)) continue;
            return callback(self.credential_context, .{ .provider_name = registered.config.name, .capabilities = registered.capabilities });
        }
        return error.ProviderConstraintUnsatisfied;
    }
};

test "production security policies reject unsafe plaintext TLS credential and cipher combinations" {
    try @import("std").testing.expectError(error.PlaintextForbidden, (RuntimeSecurityPolicy{ .environment = .production }).validate());
    try @import("std").testing.expectError(error.TlsRequired, (RuntimeSecurityPolicy{ .environment = .production, .prohibit_plaintext = true }).validate());
    try @import("std").testing.expectError(error.CredentialCallbackRequired, (RuntimeSecurityPolicy{ .environment = .production, .prohibit_plaintext = true, .require_tls = true }).validate());
    const callback = struct {
        fn validate(_: ?*anyopaque, _: SecurityCredentialRequest) SecurityPolicyError!void {}
    }.validate;
    try @import("std").testing.expectError(error.CipherSuiteRequired, (RuntimeSecurityPolicy{ .environment = .production, .prohibit_plaintext = true, .require_tls = true, .require_credentials = true, .credential_callback = callback }).validate());
}

test "security policies reject insecure dependent constraints" {
    try @import("std").testing.expectError(error.CipherRequiresTls, (RuntimeSecurityPolicy{ .required_cipher_bits = core.cipher_capability_bit(.aes_256_gcm) }).validate());
    try @import("std").testing.expectError(error.CredentialRequiresTls, (RuntimeSecurityPolicy{ .require_credentials = true }).validate());
    try @import("std").testing.expectError(error.CredentialCallbackRequired, (RuntimeSecurityPolicy{ .require_tls = true, .require_credentials = true }).validate());
}
