const core = @import("minna-san-core");
const protocol = @import("minna-san-protocol");
const transport = @import("minna-san-transport");
const topology = @import("minna-san-topology");
const state = @import("minna-san-state");
const sdk_config = @import("sdk_config.zig");
const resource_handle = @import("resource_handle.zig");
const buffer_api = @import("buffer_api.zig");
const event = @import("event.zig");
const poll_runtime = @import("poll_runtime.zig");
const managed_runtime = @import("managed_runtime.zig");
const version = @import("version.zig");

pub const ConfigError = sdk_config.ConfigError;
pub const SdkConfig = sdk_config.SdkConfig;
pub const Sdk = sdk_config.Sdk;
pub const SdkConfigBuilder = sdk_config.SdkConfigBuilder;
pub const HandleError = resource_handle.HandleError;
pub const ResourceHandle = resource_handle.ResourceHandle;
pub const ResourceRegistry = resource_handle.ResourceRegistry;
pub const SdkBuffer = buffer_api.SdkBuffer;
pub const EventMode = event.EventMode;
pub const EventOwnership = event.EventOwnership;
pub const EventBuffer = event.EventBuffer;
pub const MessageEvent = event.MessageEvent;
pub const OverflowEvent = event.OverflowEvent;
pub const EventKind = event.EventKind;
pub const Event = event.Event;
pub const EventEnvelope = event.EventEnvelope;
pub const EventOrderError = event.EventOrderError;
pub const EventOrder = event.EventOrder;
pub const PollRuntimeError = poll_runtime.PollRuntimeError;
pub const PollRuntime = poll_runtime.PollRuntime;
pub const ManagedRuntimeError = managed_runtime.ManagedRuntimeError;
pub const ManagedRuntime = managed_runtime.ManagedRuntime;
pub const DirectDispatch = managed_runtime.DirectDispatch;
pub const SdkVersion = version.SdkVersion;
pub const runtime_version = version.runtime_version;
pub const abi_version = version.abi_version;
pub const feature_version = version.feature_version;
pub const wire_version = version.wire_version;
pub const package_name = "runtime";

comptime {
    _ = core.package_name;
    _ = protocol.package_name;
    _ = transport.package_name;
    _ = topology.package_name;
    _ = state.package_name;
}

test "runtime package boundary" {
    try @import("std").testing.expectEqualStrings("runtime", package_name);
}

test {
    _ = @import("sdk_config.zig");
    _ = @import("resource_handle.zig");
    _ = @import("buffer_api.zig");
    _ = @import("event.zig");
    _ = @import("poll_runtime.zig");
    _ = @import("managed_runtime.zig");
    _ = @import("version.zig");
}
