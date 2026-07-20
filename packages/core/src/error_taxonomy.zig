const std = @import("std");

pub const ErrorClass = enum(c_int) {
    ok = 0,
    invalid_argument = 1,
    invalid_state = 2,
    unsupported = 3,
    resource_exhausted = 4,
    timeout = 5,
    cancelled = 6,
    would_block = 7,
    authentication_failed = 8,
    permission_denied = 9,
    protocol_violation = 10,
    version_mismatch = 11,
    integrity_failed = 12,
    transport_failure = 13,
    internal = 14,
};

pub const CResult = enum(c_int) {
    ok = 0,
    invalid_argument = 1,
    invalid_state = 2,
    unsupported = 3,
    resource_exhausted = 4,
    timeout = 5,
    cancelled = 6,
    would_block = 7,
    authentication_failed = 8,
    permission_denied = 9,
    protocol_violation = 10,
    version_mismatch = 11,
    integrity_failed = 12,
    transport_failure = 13,
    internal = 14,
};

pub const Retryability = enum(c_int) {
    never = 0,
    immediate = 1,
    backoff = 2,
};

pub const OperatorCategory = enum(c_int) {
    none = 0,
    caller = 1,
    lifecycle = 2,
    capability = 3,
    capacity = 4,
    scheduling = 5,
    authentication = 6,
    authorization = 7,
    protocol = 8,
    integrity = 9,
    transport = 10,
    internal = 11,
};

pub const ErrorDisposition = struct {
    class: ErrorClass,
    retryability: Retryability,
    operator_category: OperatorCategory,
};

pub const ZigError = error{
    InvalidArgument,
    InvalidState,
    Unsupported,
    ResourceExhausted,
    Timeout,
    Cancelled,
    WouldBlock,
    AuthenticationFailed,
    PermissionDenied,
    ProtocolViolation,
    VersionMismatch,
    IntegrityFailed,
    TransportFailure,
    Internal,
};

pub const all_errors = [_]ZigError{
    error.InvalidArgument,
    error.InvalidState,
    error.Unsupported,
    error.ResourceExhausted,
    error.Timeout,
    error.Cancelled,
    error.WouldBlock,
    error.AuthenticationFailed,
    error.PermissionDenied,
    error.ProtocolViolation,
    error.VersionMismatch,
    error.IntegrityFailed,
    error.TransportFailure,
    error.Internal,
};

pub fn class_for_error(err: ZigError) ErrorClass {
    return switch (err) {
        error.InvalidArgument => .invalid_argument,
        error.InvalidState => .invalid_state,
        error.Unsupported => .unsupported,
        error.ResourceExhausted => .resource_exhausted,
        error.Timeout => .timeout,
        error.Cancelled => .cancelled,
        error.WouldBlock => .would_block,
        error.AuthenticationFailed => .authentication_failed,
        error.PermissionDenied => .permission_denied,
        error.ProtocolViolation => .protocol_violation,
        error.VersionMismatch => .version_mismatch,
        error.IntegrityFailed => .integrity_failed,
        error.TransportFailure => .transport_failure,
        error.Internal => .internal,
    };
}

pub fn error_for_class(class: ErrorClass) ?ZigError {
    return switch (class) {
        .ok => null,
        .invalid_argument => error.InvalidArgument,
        .invalid_state => error.InvalidState,
        .unsupported => error.Unsupported,
        .resource_exhausted => error.ResourceExhausted,
        .timeout => error.Timeout,
        .cancelled => error.Cancelled,
        .would_block => error.WouldBlock,
        .authentication_failed => error.AuthenticationFailed,
        .permission_denied => error.PermissionDenied,
        .protocol_violation => error.ProtocolViolation,
        .version_mismatch => error.VersionMismatch,
        .integrity_failed => error.IntegrityFailed,
        .transport_failure => error.TransportFailure,
        .internal => error.Internal,
    };
}

pub fn c_result_for_class(class: ErrorClass) CResult {
    return @enumFromInt(@intFromEnum(class));
}

pub fn class_for_c_result(result: CResult) ErrorClass {
    return @enumFromInt(@intFromEnum(result));
}

pub fn c_result_for_error(err: ZigError) CResult {
    return c_result_for_class(class_for_error(err));
}

pub fn error_for_c_result(result: CResult) ?ZigError {
    return error_for_class(class_for_c_result(result));
}

pub fn disposition_for_class(class: ErrorClass) ErrorDisposition {
    return switch (class) {
        .ok => .{ .class = .ok, .retryability = .never, .operator_category = .none },
        .invalid_argument => .{ .class = .invalid_argument, .retryability = .never, .operator_category = .caller },
        .invalid_state => .{ .class = .invalid_state, .retryability = .never, .operator_category = .lifecycle },
        .unsupported => .{ .class = .unsupported, .retryability = .never, .operator_category = .capability },
        .resource_exhausted => .{ .class = .resource_exhausted, .retryability = .backoff, .operator_category = .capacity },
        .timeout => .{ .class = .timeout, .retryability = .backoff, .operator_category = .scheduling },
        .cancelled => .{ .class = .cancelled, .retryability = .never, .operator_category = .lifecycle },
        .would_block => .{ .class = .would_block, .retryability = .immediate, .operator_category = .scheduling },
        .authentication_failed => .{ .class = .authentication_failed, .retryability = .never, .operator_category = .authentication },
        .permission_denied => .{ .class = .permission_denied, .retryability = .never, .operator_category = .authorization },
        .protocol_violation, .version_mismatch => .{ .class = class, .retryability = .never, .operator_category = .protocol },
        .integrity_failed => .{ .class = .integrity_failed, .retryability = .never, .operator_category = .integrity },
        .transport_failure => .{ .class = .transport_failure, .retryability = .backoff, .operator_category = .transport },
        .internal => .{ .class = .internal, .retryability = .never, .operator_category = .internal },
    };
}

pub fn disposition_for_c_result(result: CResult) ErrorDisposition {
    return disposition_for_class(class_for_c_result(result));
}

pub fn disposition_for_any_error(err: anyerror) ErrorDisposition {
    const class: ErrorClass = switch (err) {
        error.InvalidArgument, error.InvalidConfiguration, error.InvalidName, error.InvalidRequest, error.InvalidHostname, error.InvalidIPAddressFormat, error.InvalidPlatformConfiguration, error.InvalidProviderCapabilityBits => .invalid_argument,
        error.InvalidState, error.NotStarted, error.NotListening, error.NotReady => .invalid_state,
        error.Unsupported, error.UnsupportedConfiguration, error.UnsupportedOption, error.OperationNotSupported, error.ProtocolNotSupported, error.SocketTypeNotSupported => .unsupported,
        error.OutOfMemory, error.Exhausted, error.ResourceExhausted, error.ProviderCapacityExceeded, error.QueueFull, error.SystemResources, error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => .resource_exhausted,
        error.Timeout, error.TimedOut, error.ConnectionTimedOut => .timeout,
        error.Cancelled => .cancelled,
        error.WouldBlock, error.ConnectionPending => .would_block,
        error.AuthenticationFailed => .authentication_failed,
        error.PermissionDenied, error.AccessDenied => .permission_denied,
        error.InvalidResponse, error.MalformedFrame, error.ProtocolViolation => .protocol_violation,
        error.VersionMismatch, error.InvalidProviderCapabilityVersion => .version_mismatch,
        error.IntegrityFailed => .integrity_failed,
        error.PollFailed, error.ConnectFailed, error.ConnectionFailed, error.SendFailed, error.ReceiveFailed, error.ResolutionFailed, error.Unavailable, error.TransportFailure, error.NetworkUnreachable, error.NetworkSubsystemFailed, error.TemporaryNameServerFailure, error.ConnectionResetByPeer, error.ConnectionRefused, error.ConnectionAborted, error.SocketNotConnected => .transport_failure,
        else => .internal,
    };
    return disposition_for_class(class);
}

pub fn c_result_from_code(code: c_int) ?CResult {
    inline for (std.meta.fields(CResult)) |field| {
        if (code == field.value) return @enumFromInt(field.value);
    }
    return null;
}

test "every Zig error maps losslessly to a C result" {
    for (all_errors) |err| {
        const result = c_result_for_error(err);
        try std.testing.expectEqual(err, error_for_c_result(result).?);
        try std.testing.expectEqual(class_for_error(err), class_for_c_result(result));
    }
}

test "C success and unknown result codes do not become Zig errors" {
    try std.testing.expect(error_for_c_result(.ok) == null);
    try std.testing.expectEqual(CResult.version_mismatch, c_result_from_code(11).?);
    try std.testing.expect(c_result_from_code(-1) == null);
    try std.testing.expect(c_result_from_code(15) == null);
}

test "error dispositions preserve retry and operator categories" {
    try std.testing.expectEqual(ErrorDisposition{ .class = .would_block, .retryability = .immediate, .operator_category = .scheduling }, disposition_for_any_error(error.WouldBlock));
    try std.testing.expectEqual(ErrorDisposition{ .class = .transport_failure, .retryability = .backoff, .operator_category = .transport }, disposition_for_any_error(error.ConnectionResetByPeer));
    try std.testing.expectEqual(ErrorDisposition{ .class = .invalid_argument, .retryability = .never, .operator_category = .caller }, disposition_for_any_error(error.InvalidRequest));
    try std.testing.expectEqual(disposition_for_class(.version_mismatch), disposition_for_c_result(.version_mismatch));
}
