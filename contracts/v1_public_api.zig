const std = @import("std");
const naming = @import("v1_naming.zig");
const core = @import("minna-san-core");
const protocol = @import("minna-san-protocol");
const transport = @import("minna-san-transport");
const topology = @import("minna-san-topology");
const state = @import("minna-san-state");
const runtime = @import("minna-san-runtime");
const c_abi = @import("minna-san-c-abi");

pub const stable_modules = [_][]const u8{
    "minna-san-core",
    "minna-san-protocol",
    "minna-san-transport",
    "minna-san-topology",
    "minna-san-state",
    "minna-san-runtime",
    "minna-san-c-abi",
};

pub const unsupported_reference_modules = [_][]const u8{
    "minna-san-networking",
    "minna-san-services",
};

pub fn isStableModule(name: []const u8) bool {
    for (stable_modules) |module_name| {
        if (std.mem.eql(u8, name, module_name)) return true;
    }
    return false;
}

fn contains(comptime names: []const []const u8, name: []const u8) bool {
    inline for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

fn expectExactPublicDeclarations(comptime namespace: type, comptime expected: []const []const u8) !void {
    const declarations = comptime std.meta.declarations(namespace);
    try std.testing.expectEqual(expected.len, declarations.len);
    inline for (expected) |name| try std.testing.expect(@hasDecl(namespace, name));
    inline for (declarations) |declaration| try std.testing.expect(contains(expected, declaration.name));
}

test "stable module inventory is exact" {
    try std.testing.expectEqual(@as(usize, 7), stable_modules.len);
    for (stable_modules) |module_name| try std.testing.expect(isStableModule(module_name));
    try std.testing.expect(!isStableModule("minna-san-optional-reference"));
    try std.testing.expect(!isStableModule("minna-san-networking"));
    try std.testing.expect(!isStableModule("minna-san-services"));
}

test "unsupported references are excluded from the v1 SDK" {
    try std.testing.expectEqual(@as(usize, 2), unsupported_reference_modules.len);
    for (unsupported_reference_modules) |module_name| {
        try std.testing.expect(!isStableModule(module_name));
        for (stable_modules) |stable_module_name| try std.testing.expect(!std.mem.eql(u8, stable_module_name, module_name));
    }
}

test "stable public symbols are exact" {
    try expectExactPublicDeclarations(core, &.{
        "ErrorClass",
        "CResult",
        "ZigError",
        "all_errors",
        "class_for_error",
        "error_for_class",
        "c_result_for_class",
        "class_for_c_result",
        "c_result_for_error",
        "error_for_c_result",
        "c_result_from_code",
        "Ownership",
        "BorrowedBuffer",
        "OwnedBuffer",
        "TransferError",
        "TransferredBuffer",
        "TimeNs",
        "ClockError",
        "Clock",
        "CheckedClock",
        "ManualClock",
        "Capability",
        "CapabilityError",
        "CapabilityConfig",
        "package_name",
    });
    try expectExactPublicDeclarations(protocol, &.{
        "WireVersion",
        "ExtensionRange",
        "WireEnvelope",
        "CompatibilityError",
        "v1_version",
        "extension_range",
        "validate_version",
        "validate_extension",
        "validate_envelope",
        "package_name",
    });
    try expectExactPublicDeclarations(transport, &.{"package_name"});
    try expectExactPublicDeclarations(topology, &.{"package_name"});
    try expectExactPublicDeclarations(state, &.{"package_name"});
    try expectExactPublicDeclarations(runtime, &.{
        "ConfigError",
        "SdkConfig",
        "Sdk",
        "SdkConfigBuilder",
        "HandleError",
        "ResourceHandle",
        "ResourceRegistry",
        "SdkBuffer",
        "EventMode",
        "EventOwnership",
        "EventBuffer",
        "MessageEvent",
        "OverflowEvent",
        "EventKind",
        "Event",
        "EventEnvelope",
        "EventOrderError",
        "EventOrder",
        "PollRuntimeError",
        "PollRuntime",
        "ManagedRuntimeError",
        "ManagedRuntime",
        "DirectDispatch",
        "SdkVersion",
        "runtime_version",
        "abi_version",
        "feature_version",
        "wire_version",
        "package_name",
    });
    try expectExactPublicDeclarations(c_abi, &.{
        "CAbiVersion",
        "CAbiHandle",
        "CVersion",
        "CDurationNs",
        "CAddressFamily",
        "CAddress",
        "CBuffer",
        "CAllocateFn",
        "CReleaseFn",
        "CAllocator",
        "CAllocatorError",
        "CBufferReleaseError",
        "CResult",
        "CErrorCategory",
        "CEventKind",
        "CEvent",
        "CNowFn",
        "CSdk",
        "CConnection",
        "CPeer",
        "CChannel",
        "CAuthoritativeSession",
        "CSdkConfig",
        "CRouteState",
        "CChannelMode",
        "CAdmissionDecision",
        "CAdmissionFn",
        "CAuthoritativeSessionConfig",
        "CCandidateKind",
        "CCandidate",
        "CP2PConfig",
        "CStunTurnConfig",
        "CMigrationConfig",
        "CTopologyConfig",
        "CReplicationTemplate",
        "CStateTransformFn",
        "CStateTransferConfig",
        "CTransportKind",
        "CSocketOptions",
        "CTransportControl",
        "CTransportConfig",
        "CSecurityConfig",
        "c_abi_version",
        "c_capability_transport",
        "c_capability_packet_protection",
        "c_capability_topology",
        "c_capability_state_replication",
        "c_capability_capture",
        "c_transport_udp",
        "c_transport_tcp",
        "c_route_direct",
        "c_route_relay",
        "c_channel_reliable",
        "c_channel_sequenced",
        "c_security_psk",
        "c_security_public_key",
        "c_security_aead",
        "c_security_replay_protection",
        "c_security_key_rotation",
        "c_admission_accept",
        "c_admission_reject",
        "c_candidate_host",
        "c_candidate_server_reflexive",
        "c_candidate_relay",
        "c_replication_authoritative",
        "c_replication_client_prediction",
        "c_replication_reconciliation",
        "is_valid_buffer",
        "allocate_buffer",
        "release_buffer",
        "result_is_known",
        "result_category",
        "result_message",
        "validate_sdk_config",
        "is_valid_address",
        "is_valid_socket_options",
        "is_valid_transport_control",
        "validate_transport_config",
        "is_valid_route_state",
        "is_valid_channel_mode",
        "is_nonempty_buffer",
        "validate_security_config",
        "validate_authoritative_session_config",
        "is_valid_candidate_kind",
        "validate_candidate",
        "validate_topology_config",
        "is_valid_replication_template",
        "validate_state_transfer_config",
        "minna_san_abi_version",
        "minna_san_abi_supports_version",
        "minna_san_result_is_known",
        "minna_san_result_category",
        "minna_san_result_message",
        "minna_san_sdk_validate_config",
        "minna_san_sdk_create",
        "minna_san_sdk_start",
        "minna_san_sdk_poll",
        "minna_san_sdk_stop",
        "minna_san_sdk_destroy",
        "minna_san_connection_open",
        "minna_san_connection_close",
        "minna_san_connection_peer",
        "minna_san_connection_route_state",
        "minna_san_connection_set_route_state",
        "minna_san_event_kind",
        "minna_san_event_mode",
        "minna_san_event_sequence",
        "minna_san_event_payload",
        "minna_san_channel_open",
        "minna_san_channel_close",
        "minna_san_channel_mode",
        "minna_san_channel_send",
        "minna_san_channel_receive",
        "minna_san_channel_acknowledge",
        "minna_san_channel_last_acknowledged",
        "minna_san_sdk_buffer_release",
        "minna_san_security_config_init",
        "minna_san_security_config_set_psk",
        "minna_san_security_config_set_public_key",
        "minna_san_security_config_set_aead_key",
        "minna_san_security_config_set_replay_window",
        "minna_san_security_config_set_key_rotation",
        "minna_san_security_config_validate",
        "minna_san_authoritative_session_config_init",
        "minna_san_authoritative_session_config_validate",
        "minna_san_authoritative_session_create",
        "minna_san_authoritative_session_destroy",
        "minna_san_authoritative_session_client_join",
        "minna_san_authoritative_session_client_leave",
        "minna_san_authoritative_session_client_count",
        "minna_san_topology_config_init",
        "minna_san_topology_config_set_p2p",
        "minna_san_topology_config_set_stun_turn",
        "minna_san_topology_config_set_migration",
        "minna_san_topology_config_validate",
        "minna_san_state_transfer_config_init",
        "minna_san_state_transfer_config_set_callbacks",
        "minna_san_state_transfer_config_set_snapshot_limits",
        "minna_san_state_transfer_config_set_recovery",
        "minna_san_state_transfer_config_validate",
        "minna_san_state_transfer_serialize",
        "minna_san_state_transfer_deserialize",
        "minna_san_transport_config_init",
        "minna_san_transport_config_set_kind",
        "minna_san_transport_config_set_local_address",
        "minna_san_transport_config_set_remote_address",
        "minna_san_transport_config_set_socket_options",
        "minna_san_transport_config_set_control",
        "minna_san_transport_config_validate",
        "package_name",
    });
}

test "stable public symbols follow namespace policy" {
    try naming.expectZigNamespace(core);
    try naming.expectZigNamespace(protocol);
    try naming.expectZigNamespace(transport);
    try naming.expectZigNamespace(topology);
    try naming.expectZigNamespace(state);
    try naming.expectZigNamespace(runtime);
    try naming.expectZigNamespace(c_abi);
}
