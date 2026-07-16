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
