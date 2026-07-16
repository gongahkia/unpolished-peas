const std = @import("std");

pub const Capability = enum {
    transport,
    packet_protection,
    topology,
    state_replication,
    capture,
};

pub const CapabilityError = error{UnsupportedCapabilityCombination};

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
