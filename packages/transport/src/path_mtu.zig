const std = @import("std");
const udp_socket = @import("udp_socket.zig");
const ipv4 = @import("ipv4.zig");

pub const max_path_mtu_probes: usize = 64;
pub const PathMtuProbeError = error{ InvalidConfiguration, ProbeLimitReached, NoProbePending, ProbeMismatch, ProbeStorageTooSmall, SendFailed };

pub const PathMtuProbeConfig = struct {
    minimum_payload: usize,
    maximum_payload: usize,
    maximum_probes: usize = max_path_mtu_probes,
};

pub const PathMtuProber = struct {
    minimum_payload: usize,
    highest_possible: usize,
    maximum_probes: usize,
    probe_count: usize = 0,
    pending_payload: ?usize = null,

    pub fn init(config: PathMtuProbeConfig) PathMtuProbeError!PathMtuProber {
        if (config.minimum_payload == 0 or config.minimum_payload > config.maximum_payload or config.maximum_payload > udp_socket.max_ipv4_datagram_bytes or config.maximum_probes == 0 or config.maximum_probes > max_path_mtu_probes) return error.InvalidConfiguration;
        return .{
            .minimum_payload = config.minimum_payload,
            .highest_possible = config.maximum_payload,
            .maximum_probes = config.maximum_probes,
        };
    }

    pub fn next_probe(self: *PathMtuProber) PathMtuProbeError!?usize {
        if (self.pending_payload) |payload| return payload;
        if (self.probe_count == self.maximum_probes) return error.ProbeLimitReached;
        if (self.minimum_payload == self.highest_possible) return null;
        const payload = self.minimum_payload + (self.highest_possible - self.minimum_payload + 1) / 2;
        self.pending_payload = payload;
        return payload;
    }

    pub fn record_delivery(self: *PathMtuProber, payload: usize, delivered: bool) PathMtuProbeError!void {
        if (self.pending_payload == null) return error.NoProbePending;
        if (self.pending_payload.? != payload) return error.ProbeMismatch;
        if (delivered) self.minimum_payload = payload else self.highest_possible = payload - 1;
        self.pending_payload = null;
        self.probe_count += 1;
    }

    pub fn payload_budget(self: PathMtuProber) usize {
        return self.minimum_payload;
    }

    pub fn payload_ceiling(self: PathMtuProber) usize {
        return self.highest_possible;
    }

    pub fn send_probe(self: *PathMtuProber, socket: *udp_socket.UdpSocket, peer: ipv4.Ipv4Address, storage: []const u8) PathMtuProbeError!?usize {
        const payload = try self.next_probe() orelse return null;
        if (storage.len < payload) return error.ProbeStorageTooSmall;
        _ = socket.send_to(storage[0..payload], peer) catch return error.SendFailed;
        return payload;
    }
};

test "path-MTU probes converge on the highest delivered bounded payload" {
    var prober = try PathMtuProber.init(.{ .minimum_payload = 100, .maximum_payload = 1_000, .maximum_probes = 16 });
    const first = (try prober.next_probe()).?;
    try std.testing.expectEqual(@as(usize, 550), first);
    try prober.record_delivery(first, true);
    const second = (try prober.next_probe()).?;
    try std.testing.expectEqual(@as(usize, 775), second);
    try prober.record_delivery(second, false);
    while (try prober.next_probe()) |payload| try prober.record_delivery(payload, payload <= 700);
    try std.testing.expectEqual(@as(usize, 700), prober.payload_budget());
    try std.testing.expectEqual(@as(usize, 700), prober.payload_ceiling());
}

test "path-MTU probes validate bounded configuration and result matching" {
    try std.testing.expectError(error.InvalidConfiguration, PathMtuProber.init(.{ .minimum_payload = 0, .maximum_payload = 1 }));
    var prober = try PathMtuProber.init(.{ .minimum_payload = 100, .maximum_payload = 200 });
    const payload = (try prober.next_probe()).?;
    try std.testing.expectError(error.ProbeMismatch, prober.record_delivery(payload - 1, true));
    try prober.record_delivery(payload, true);
    try std.testing.expectError(error.NoProbePending, prober.record_delivery(payload, true));
}
