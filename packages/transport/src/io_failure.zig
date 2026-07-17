const std = @import("std");

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

pub const TransportRetryHint = enum {
    immediate,
    backoff,
    never,
};

pub const TransportIoFailure = struct {
    category: TransportIoErrorCategory,
    retry: TransportRetryHint,
};

pub fn normalize_io_failure(err: anyerror) TransportIoFailure {
    return switch (err) {
        error.WouldBlock, error.ConnectionPending => .{ .category = .would_block, .retry = .immediate },
        error.TemporaryNameServerFailure, error.NetworkUnreachable, error.NetworkSubsystemFailed, error.ConnectionTimedOut, error.SystemResources => .{ .category = .retryable_network, .retry = .backoff },
        error.ConnectionResetByPeer, error.ConnectionRefused, error.ConnectionAborted, error.SocketNotConnected => .{ .category = .peer_closed, .retry = .backoff },
        error.AddressInUse, error.AddressNotAvailable, error.AddressFamilyNotSupported, error.InvalidCharacter, error.InvalidEnd, error.InvalidIPAddressFormat => .{ .category = .configuration, .retry = .never },
        error.OutOfMemory, error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => .{ .category = .resource_exhausted, .retry = .backoff },
        error.InvalidProtocolOption, error.OperationNotSupported, error.ProtocolNotSupported, error.SocketTypeNotSupported => .{ .category = .unsupported, .retry = .never },
        error.AccessDenied, error.PermissionDenied, error.UnknownHostName, error.HostLacksNetworkAddresses => .{ .category = .terminal, .retry = .never },
        else => .{ .category = .unknown, .retry = .never },
    };
}

test "transport I/O failure normalization preserves retry semantics" {
    try std.testing.expectEqual(TransportIoFailure{ .category = .would_block, .retry = .immediate }, normalize_io_failure(error.WouldBlock));
    try std.testing.expectEqual(TransportIoFailure{ .category = .retryable_network, .retry = .backoff }, normalize_io_failure(error.TemporaryNameServerFailure));
    try std.testing.expectEqual(TransportIoFailure{ .category = .peer_closed, .retry = .backoff }, normalize_io_failure(error.ConnectionResetByPeer));
    try std.testing.expectEqual(TransportIoFailure{ .category = .configuration, .retry = .never }, normalize_io_failure(error.AddressInUse));
}

test "transport I/O failure normalization preserves terminal and unknown failures" {
    try std.testing.expectEqual(TransportIoFailure{ .category = .resource_exhausted, .retry = .backoff }, normalize_io_failure(error.OutOfMemory));
    try std.testing.expectEqual(TransportIoFailure{ .category = .unsupported, .retry = .never }, normalize_io_failure(error.OperationNotSupported));
    try std.testing.expectEqual(TransportIoFailure{ .category = .terminal, .retry = .never }, normalize_io_failure(error.UnknownHostName));
    try std.testing.expectEqual(TransportIoFailure{ .category = .unknown, .retry = .never }, normalize_io_failure(error.Unexpected));
}
