pub const configuration_version: u32 = 1;
pub const max_provider_capacity: usize = 64;
pub const max_service_capacity: usize = 256;
pub const max_session_capacity: usize = 65_536;
pub const max_channel_capacity: usize = 1_048_576;
pub const max_event_capacity: usize = 1_048_576;
pub const max_poll_work_budget: usize = 1_048_576;

pub const PlatformLimits = struct {
    provider_capacity: usize = 8,
    service_capacity: usize = 16,
    session_capacity: usize = 256,
    channel_capacity: usize = 1_024,
    event_capacity: usize = 1_024,
    poll_work_budget: usize = 256,
};

pub const PlatformConfig = struct {
    version: u32 = configuration_version,
    limits: PlatformLimits = .{},

    pub fn validate(self: PlatformConfig) error{ InvalidConfigurationVersion, InvalidProviderCapacity, InvalidServiceCapacity, InvalidSessionCapacity, InvalidChannelCapacity, InvalidEventCapacity, InvalidPollWorkBudget }!void {
        if (self.version != configuration_version) return error.InvalidConfigurationVersion;
        if (self.limits.provider_capacity == 0 or self.limits.provider_capacity > max_provider_capacity) return error.InvalidProviderCapacity;
        if (self.limits.service_capacity > max_service_capacity) return error.InvalidServiceCapacity;
        if (self.limits.session_capacity == 0 or self.limits.session_capacity > max_session_capacity) return error.InvalidSessionCapacity;
        if (self.limits.channel_capacity == 0 or self.limits.channel_capacity > max_channel_capacity) return error.InvalidChannelCapacity;
        if (self.limits.event_capacity == 0 or self.limits.event_capacity > max_event_capacity) return error.InvalidEventCapacity;
        if (self.limits.poll_work_budget == 0 or self.limits.poll_work_budget > max_poll_work_budget) return error.InvalidPollWorkBudget;
    }
};

test "platform configuration accepts bounded defaults" {
    try (PlatformConfig{}).validate();
}

test "platform configuration rejects unsupported versions and capacities" {
    try @import("std").testing.expectError(error.InvalidConfigurationVersion, (PlatformConfig{ .version = configuration_version + 1 }).validate());
    try @import("std").testing.expectError(error.InvalidProviderCapacity, (PlatformConfig{ .limits = .{ .provider_capacity = 0 } }).validate());
    try @import("std").testing.expectError(error.InvalidSessionCapacity, (PlatformConfig{ .limits = .{ .session_capacity = max_session_capacity + 1 } }).validate());
    try @import("std").testing.expectError(error.InvalidPollWorkBudget, (PlatformConfig{ .limits = .{ .poll_work_budget = 0 } }).validate());
}
