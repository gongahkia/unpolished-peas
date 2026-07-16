const core = @import("minna-san-core");

pub const ConfigError = core.CapabilityError || error{MissingClock};

pub const SdkConfig = struct {
    clock_value: core.Clock,
    capability_config: core.CapabilityConfig,

    pub fn clock(self: SdkConfig) core.Clock {
        return self.clock_value;
    }

    pub fn is_capability_enabled(self: SdkConfig, capability: core.Capability) bool {
        return self.capability_config.is_enabled(capability);
    }
};

pub const Sdk = struct {
    config: SdkConfig,

    pub fn configuration(self: Sdk) SdkConfig {
        return self.config;
    }
};

pub const SdkConfigBuilder = struct {
    clock_value: ?core.Clock = null,
    capability_config: core.CapabilityConfig = .{},

    pub fn init() SdkConfigBuilder {
        return .{};
    }

    pub fn with_clock(self: SdkConfigBuilder, clock: core.Clock) SdkConfigBuilder {
        var next = self;
        next.clock_value = clock;
        return next;
    }

    pub fn enable(self: SdkConfigBuilder, capability: core.Capability) SdkConfigBuilder {
        var next = self;
        next.capability_config.enable(capability);
        return next;
    }

    pub fn build(self: SdkConfigBuilder) ConfigError!Sdk {
        const clock = self.clock_value orelse return error.MissingClock;
        try self.capability_config.validate();
        return .{ .config = .{ .clock_value = clock, .capability_config = self.capability_config } };
    }
};

test "SDK builders construct immutable validated configurations" {
    var manual = core.ManualClock.init(42);
    const builder = SdkConfigBuilder.init().with_clock(manual.clock()).enable(.transport).enable(.topology);
    const sdk = try builder.build();
    try @import("std").testing.expect(sdk.configuration().is_capability_enabled(.transport));
    try @import("std").testing.expect(sdk.configuration().is_capability_enabled(.topology));
    try @import("std").testing.expectEqual(@as(core.TimeNs, 42), sdk.configuration().clock().now());
}

test "SDK builders reject missing and unsupported configuration" {
    try @import("std").testing.expectError(error.MissingClock, SdkConfigBuilder.init().build());
    var manual = core.ManualClock.init(0);
    const invalid = SdkConfigBuilder.init().with_clock(manual.clock()).enable(.packet_protection);
    try @import("std").testing.expectError(error.UnsupportedCapabilityCombination, invalid.build());
}
