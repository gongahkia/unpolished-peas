const std = @import("std");

pub const max_tls_alpn_protocols: usize = 16;
pub const max_tls_alpn_protocol_bytes: usize = 255;
pub const tls_alpn_http_1_1 = "http/1.1";
pub const tls_alpn_http_2 = "h2";
pub const TlsAlpnError = error{ InvalidConfiguration, InvalidProtocol, DuplicateProtocol, RequiredProtocolUnsupported, NoApplicationProtocol };

pub const TlsAlpnRoutePolicy = struct {
    supported: []const []const u8,
    required: ?[]const u8 = null,

    pub fn validate(self: TlsAlpnRoutePolicy) TlsAlpnError!void {
        try validateProtocols(self.supported);
        if (self.required) |required| {
            try validateProtocol(required);
            if (!contains(self.supported, required)) return error.RequiredProtocolUnsupported;
        }
    }
};

pub fn select_tls_alpn(offered: []const []const u8, policy: TlsAlpnRoutePolicy) TlsAlpnError![]const u8 {
    try validateProtocols(offered);
    try policy.validate();
    if (policy.required) |required| return if (contains(offered, required)) required else error.NoApplicationProtocol;
    for (policy.supported) |supported| if (contains(offered, supported)) return supported;
    return error.NoApplicationProtocol;
}

fn validateProtocols(protocols: []const []const u8) TlsAlpnError!void {
    if (protocols.len == 0 or protocols.len > max_tls_alpn_protocols) return error.InvalidConfiguration;
    for (protocols, 0..) |protocol, index| {
        try validateProtocol(protocol);
        for (protocols[index + 1 ..]) |other| if (std.mem.eql(u8, protocol, other)) return error.DuplicateProtocol;
    }
}

fn validateProtocol(protocol: []const u8) TlsAlpnError!void {
    if (protocol.len == 0 or protocol.len > max_tls_alpn_protocol_bytes) return error.InvalidProtocol;
}

fn contains(protocols: []const []const u8, wanted: []const u8) bool {
    for (protocols) |protocol| if (std.mem.eql(u8, protocol, wanted)) return true;
    return false;
}

test "TLS ALPN selects server-preferred HTTP and provider protocols before application parsing" {
    const offered = [_][]const u8{ tls_alpn_http_1_1, tls_alpn_http_2, "minna-san/1" };
    const policy = TlsAlpnRoutePolicy{ .supported = &.{ "minna-san/1", tls_alpn_http_2, tls_alpn_http_1_1 } };
    try std.testing.expectEqualStrings("minna-san/1", try select_tls_alpn(offered[0..], policy));
    try std.testing.expectEqualStrings(tls_alpn_http_2, try select_tls_alpn(offered[0..], .{ .supported = &.{ tls_alpn_http_1_1, tls_alpn_http_2 }, .required = tls_alpn_http_2 }));
    try std.testing.expectError(error.NoApplicationProtocol, select_tls_alpn(&.{tls_alpn_http_1_1}, .{ .supported = &.{tls_alpn_http_2} }));
    try std.testing.expectError(error.NoApplicationProtocol, select_tls_alpn(&.{tls_alpn_http_1_1}, .{ .supported = &.{ tls_alpn_http_1_1, tls_alpn_http_2 }, .required = tls_alpn_http_2 }));
}
