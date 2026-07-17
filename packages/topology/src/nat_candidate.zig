const core = @import("minna-san-core");
const transport = @import("minna-san-transport");

pub const NatCandidateKind = enum { host, server_reflexive, relay };
pub const NatCandidateTransport = enum { udp, tcp };

pub const NatCandidateAddress = union(enum) {
    ipv4: transport.Ipv4Address,
    ipv6: transport.Ipv6Address,
};

pub const NatCandidateCredentials = struct {
    username: []const u8,
    password: []const u8,
    expires_at_ns: core.TimeNs,
};

pub const NatCandidate = struct {
    kind: NatCandidateKind,
    transport: NatCandidateTransport,
    address: NatCandidateAddress,
    priority: u32,
    expires_at_ns: core.TimeNs,
    credentials: ?NatCandidateCredentials = null,
};

pub const NatCandidateError = error{ InvalidCandidate, ExpiredCandidate };

pub fn validate_nat_candidate(candidate: NatCandidate, now_ns: core.TimeNs) NatCandidateError!void {
    if (candidate.priority == 0 or candidate.expires_at_ns <= now_ns or address_port(candidate.address) == 0) return error.InvalidCandidate;
    if (candidate.credentials) |credentials| {
        if (credentials.username.len == 0 or credentials.password.len == 0 or credentials.expires_at_ns <= now_ns or credentials.expires_at_ns > candidate.expires_at_ns) return error.InvalidCandidate;
    } else if (candidate.kind == .relay) return error.InvalidCandidate;
}

pub fn candidate_expired(candidate: NatCandidate, now_ns: core.TimeNs) bool {
    return candidate.expires_at_ns <= now_ns or if (candidate.credentials) |credentials| credentials.expires_at_ns <= now_ns else false;
}

fn address_port(address: NatCandidateAddress) u16 {
    return switch (address) {
        .ipv4 => |ipv4| ipv4.port,
        .ipv6 => |ipv6| ipv6.port,
    };
}

test "NAT candidates validate host reflexive relay address expiry and credentials" {
    const host = NatCandidate{ .kind = .host, .transport = .udp, .address = .{ .ipv4 = .{ .octets = .{ 10, 0, 0, 1 }, .port = 3478 } }, .priority = 1, .expires_at_ns = 10 };
    try validate_nat_candidate(host, 0);
    const relay = NatCandidate{ .kind = .relay, .transport = .tcp, .address = .{ .ipv6 = .{ .octets = .{0} ** 15 ++ .{1}, .port = 3479, .scope_id = 0 } }, .priority = 2, .expires_at_ns = 10, .credentials = .{ .username = "u", .password = "p", .expires_at_ns = 9 } };
    try validate_nat_candidate(relay, 0);
    try @import("std").testing.expect(!candidate_expired(relay, 8));
    try @import("std").testing.expect(candidate_expired(relay, 9));
}

test "NAT candidates reject invalid expiry addresses and relay credentials" {
    const valid = NatCandidate{ .kind = .host, .transport = .udp, .address = .{ .ipv4 = .{ .octets = .{ 127, 0, 0, 1 }, .port = 1 } }, .priority = 1, .expires_at_ns = 2 };
    var invalid = valid;
    invalid.priority = 0;
    try @import("std").testing.expectError(error.InvalidCandidate, validate_nat_candidate(invalid, 0));
    invalid = valid;
    invalid.expires_at_ns = 0;
    try @import("std").testing.expectError(error.InvalidCandidate, validate_nat_candidate(invalid, 0));
    invalid = valid;
    invalid.address = .{ .ipv4 = .{ .octets = .{ 127, 0, 0, 1 }, .port = 0 } };
    try @import("std").testing.expectError(error.InvalidCandidate, validate_nat_candidate(invalid, 0));
    invalid = valid;
    invalid.kind = .relay;
    try @import("std").testing.expectError(error.InvalidCandidate, validate_nat_candidate(invalid, 0));
}
