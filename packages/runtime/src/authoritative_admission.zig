const std = @import("std");
const core = @import("minna-san-core");
const protocol = @import("minna-san-protocol");
const host = @import("authoritative_host.zig");

pub const AdmissionDecision = enum { accepted, identity_rejected, protocol_rejected, rate_limited, capacity_rejected, authorization_rejected, already_admitted };
pub const AuthoritativeAdmissionError = std.mem.Allocator.Error || error{ InvalidConfiguration, ClockRegression, UnknownPeer };

pub const AdmissionRequest = struct {
    peer: host.HostPeerId,
    version: protocol.WireVersion,
};

pub const AdmissionAuthorization = struct {
    context: *anyopaque,
    authorize_fn: *const fn (*anyopaque, AdmissionRequest) bool,

    pub fn authorize(self: AdmissionAuthorization, request: AdmissionRequest) bool {
        return self.authorize_fn(self.context, request);
    }
};

pub const AuthoritativeAdmissionConfig = struct {
    maximum_active_peers: usize,
    maximum_attempts_per_window: usize,
    attempt_window_ns: core.TimeNs,
    allowed_identities: []const host.HostPeerId = &.{},
    authorization: ?AdmissionAuthorization = null,
};

pub const AuthoritativeAdmission = struct {
    allocator: std.mem.Allocator,
    config: AuthoritativeAdmissionConfig,
    active: std.ArrayListUnmanaged(host.HostPeerId) = .empty,
    window_started_ns: ?core.TimeNs = null,
    attempts_in_window: usize = 0,
    last_now_ns: ?core.TimeNs = null,

    pub fn init(allocator: std.mem.Allocator, config: AuthoritativeAdmissionConfig) AuthoritativeAdmissionError!AuthoritativeAdmission {
        if (config.maximum_active_peers == 0 or config.maximum_attempts_per_window == 0 or config.attempt_window_ns == 0) return error.InvalidConfiguration;
        for (config.allowed_identities) |identity| if (identity == 0) return error.InvalidConfiguration;
        return .{ .allocator = allocator, .config = config };
    }

    pub fn deinit(self: *AuthoritativeAdmission) void {
        self.active.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn active_count(self: AuthoritativeAdmission) usize {
        return self.active.items.len;
    }

    pub fn admit(self: *AuthoritativeAdmission, request: AdmissionRequest, now_ns: core.TimeNs) AuthoritativeAdmissionError!AdmissionDecision {
        if (self.last_now_ns) |previous| if (now_ns < previous) return error.ClockRegression;
        self.last_now_ns = now_ns;
        if (request.peer == 0 or !self.identity_allowed(request.peer)) return .identity_rejected;
        protocol.validate_version(request.version) catch return .protocol_rejected;
        if (self.contains(request.peer)) return .already_admitted;
        self.refresh_rate_window(now_ns);
        if (self.attempts_in_window == self.config.maximum_attempts_per_window) return .rate_limited;
        self.attempts_in_window += 1;
        if (self.active.items.len == self.config.maximum_active_peers) return .capacity_rejected;
        if (self.config.authorization) |authorization| if (!authorization.authorize(request)) return .authorization_rejected;
        try self.active.append(self.allocator, request.peer);
        return .accepted;
    }

    pub fn release(self: *AuthoritativeAdmission, peer: host.HostPeerId) AuthoritativeAdmissionError!void {
        for (self.active.items, 0..) |active_peer, index| {
            if (active_peer != peer) continue;
            for (self.active.items[index + 1 ..], index..) |next, destination| self.active.items[destination] = next;
            self.active.items.len -= 1;
            return;
        }
        return error.UnknownPeer;
    }

    fn identity_allowed(self: AuthoritativeAdmission, peer: host.HostPeerId) bool {
        if (self.config.allowed_identities.len == 0) return true;
        for (self.config.allowed_identities) |identity| if (identity == peer) return true;
        return false;
    }

    fn contains(self: AuthoritativeAdmission, peer: host.HostPeerId) bool {
        for (self.active.items) |active_peer| if (active_peer == peer) return true;
        return false;
    }

    fn refresh_rate_window(self: *AuthoritativeAdmission, now_ns: core.TimeNs) void {
        const started = self.window_started_ns orelse {
            self.window_started_ns = now_ns;
            return;
        };
        if (now_ns - started < self.config.attempt_window_ns) return;
        self.window_started_ns = now_ns;
        self.attempts_in_window = 0;
    }
};

test "authoritative admission applies identity protocol capacity and authorization decisions" {
    const Fixture = struct {
        fn authorize(_: *anyopaque, request: AdmissionRequest) bool {
            return request.peer == 7;
        }
    };
    var fixture = Fixture{};
    const allowed = [_]host.HostPeerId{ 7, 8 };
    var admission = try AuthoritativeAdmission.init(std.testing.allocator, .{
        .maximum_active_peers = 1,
        .maximum_attempts_per_window = 4,
        .attempt_window_ns = 10,
        .allowed_identities = allowed[0..],
        .authorization = .{ .context = &fixture, .authorize_fn = Fixture.authorize },
    });
    defer admission.deinit();
    try std.testing.expectEqual(AdmissionDecision.identity_rejected, try admission.admit(.{ .peer = 9, .version = protocol.v1_version }, 0));
    try std.testing.expectEqual(AdmissionDecision.protocol_rejected, try admission.admit(.{ .peer = 7, .version = .{ .major = 2, .minor = 0 } }, 0));
    try std.testing.expectEqual(AdmissionDecision.accepted, try admission.admit(.{ .peer = 7, .version = protocol.v1_version }, 0));
    try std.testing.expectEqual(AdmissionDecision.already_admitted, try admission.admit(.{ .peer = 7, .version = protocol.v1_version }, 1));
    try std.testing.expectEqual(AdmissionDecision.capacity_rejected, try admission.admit(.{ .peer = 8, .version = protocol.v1_version }, 1));
    try admission.release(7);
    try std.testing.expectEqual(AdmissionDecision.authorization_rejected, try admission.admit(.{ .peer = 8, .version = protocol.v1_version }, 2));
    try std.testing.expectEqual(@as(usize, 0), admission.active_count());
}

test "authoritative admission bounds rate windows and monotonic time" {
    var admission = try AuthoritativeAdmission.init(std.testing.allocator, .{
        .maximum_active_peers = 2,
        .maximum_attempts_per_window = 1,
        .attempt_window_ns = 10,
    });
    defer admission.deinit();
    try std.testing.expectEqual(AdmissionDecision.accepted, try admission.admit(.{ .peer = 1, .version = protocol.v1_version }, 0));
    try admission.release(1);
    try std.testing.expectEqual(AdmissionDecision.rate_limited, try admission.admit(.{ .peer = 2, .version = protocol.v1_version }, 1));
    try std.testing.expectEqual(AdmissionDecision.accepted, try admission.admit(.{ .peer = 2, .version = protocol.v1_version }, 10));
    try std.testing.expectError(error.ClockRegression, admission.admit(.{ .peer = 3, .version = protocol.v1_version }, 9));
    try std.testing.expectError(error.InvalidConfiguration, AuthoritativeAdmission.init(std.testing.allocator, .{
        .maximum_active_peers = 0,
        .maximum_attempts_per_window = 1,
        .attempt_window_ns = 1,
    }));
}
