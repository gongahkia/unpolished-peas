const std = @import("std");
const core = @import("minna-san-core");

pub const TransportIoErrorCategory = enum {
    would_block,
    retryable_network,
    peer_closed,
    configuration,
    resource_exhausted,
    unsupported,
    terminal,
    unknown,
};

pub const TransportRetryHint = core.Retryability;

pub const TransportIoFailure = struct {
    category: TransportIoErrorCategory,
    retry: TransportRetryHint,
    class: core.ErrorClass,
    operator_category: core.OperatorCategory,
};

pub fn normalize_io_failure(err: anyerror) TransportIoFailure {
    return switch (err) {
        error.WouldBlock, error.ConnectionPending => failure(.would_block, .would_block),
        error.TemporaryNameServerFailure, error.NetworkUnreachable, error.NetworkSubsystemFailed => failure(.retryable_network, .transport_failure),
        error.ConnectionTimedOut => failure(.retryable_network, .timeout),
        error.SystemResources => failure(.retryable_network, .resource_exhausted),
        error.ConnectionResetByPeer, error.ConnectionRefused, error.ConnectionAborted, error.SocketNotConnected => failure(.peer_closed, .transport_failure),
        error.AddressInUse, error.AddressNotAvailable, error.AddressFamilyNotSupported, error.InvalidCharacter, error.InvalidEnd, error.InvalidIPAddressFormat => failure(.configuration, .invalid_argument),
        error.OutOfMemory, error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => failure(.resource_exhausted, .resource_exhausted),
        error.InvalidProtocolOption, error.OperationNotSupported, error.ProtocolNotSupported, error.SocketTypeNotSupported => failure(.unsupported, .unsupported),
        error.AccessDenied, error.PermissionDenied => failure(.terminal, .permission_denied),
        error.UnknownHostName, error.HostLacksNetworkAddresses => failure(.terminal, .invalid_argument),
        else => failure(.unknown, .internal),
    };
}

fn failure(category: TransportIoErrorCategory, class: core.ErrorClass) TransportIoFailure {
    const disposition = core.disposition_for_class(class);
    return .{ .category = category, .retry = disposition.retryability, .class = class, .operator_category = disposition.operator_category };
}

test "transport I/O failure normalization preserves retry semantics" {
    try std.testing.expectEqual(TransportIoFailure{ .category = .would_block, .retry = .immediate, .class = .would_block, .operator_category = .scheduling }, normalize_io_failure(error.WouldBlock));
    try std.testing.expectEqual(TransportIoFailure{ .category = .retryable_network, .retry = .backoff, .class = .transport_failure, .operator_category = .transport }, normalize_io_failure(error.TemporaryNameServerFailure));
    try std.testing.expectEqual(TransportIoFailure{ .category = .peer_closed, .retry = .backoff, .class = .transport_failure, .operator_category = .transport }, normalize_io_failure(error.ConnectionResetByPeer));
    try std.testing.expectEqual(TransportIoFailure{ .category = .configuration, .retry = .never, .class = .invalid_argument, .operator_category = .caller }, normalize_io_failure(error.AddressInUse));
}

test "transport I/O failure normalization preserves terminal and unknown failures" {
    try std.testing.expectEqual(TransportIoFailure{ .category = .resource_exhausted, .retry = .backoff, .class = .resource_exhausted, .operator_category = .capacity }, normalize_io_failure(error.OutOfMemory));
    try std.testing.expectEqual(TransportIoFailure{ .category = .unsupported, .retry = .never, .class = .unsupported, .operator_category = .capability }, normalize_io_failure(error.OperationNotSupported));
    try std.testing.expectEqual(TransportIoFailure{ .category = .terminal, .retry = .never, .class = .invalid_argument, .operator_category = .caller }, normalize_io_failure(error.UnknownHostName));
    try std.testing.expectEqual(TransportIoFailure{ .category = .unknown, .retry = .never, .class = .internal, .operator_category = .internal }, normalize_io_failure(error.Unexpected));
}
