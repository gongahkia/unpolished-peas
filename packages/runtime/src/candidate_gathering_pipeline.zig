const std = @import("std");
const core = @import("minna-san-core");
const protocol = @import("minna-san-protocol");
const topology = @import("minna-san-topology");

pub const max_gathered_candidates: usize = core.max_session_capacity;
pub const CandidateGatheringPipelineError = std.mem.Allocator.Error || topology.NatCandidateError || error{ InvalidConfiguration, CandidateCapacityExceeded, OutputTooSmall };
pub const CandidateGatheringPipelineConfig = struct {
    maximum_candidates: usize = 64,
    host_lifetime_ns: core.TimeNs,
    server_reflexive_lifetime_ns: core.TimeNs,
    relay_lifetime_ns: core.TimeNs,
    host_priority: u32 = 10,
    server_reflexive_priority: u32 = 20,
    relay_priority: u32 = 30,

    pub fn validate(self: CandidateGatheringPipelineConfig) CandidateGatheringPipelineError!void {
        if (self.maximum_candidates == 0 or self.maximum_candidates > max_gathered_candidates or self.host_lifetime_ns == 0 or self.server_reflexive_lifetime_ns == 0 or self.relay_lifetime_ns == 0) return error.InvalidConfiguration;
    }
};

pub const CandidateGatheringPipeline = struct {
    allocator: std.mem.Allocator,
    config: CandidateGatheringPipelineConfig,
    candidates: std.ArrayListUnmanaged(topology.NatCandidate) = .empty,

    pub fn init(allocator: std.mem.Allocator, config: CandidateGatheringPipelineConfig) CandidateGatheringPipelineError!CandidateGatheringPipeline {
        try config.validate();
        return .{ .allocator = allocator, .config = config };
    }

    pub fn deinit(self: *CandidateGatheringPipeline) void {
        self.candidates.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn observeHost(self: *CandidateGatheringPipeline, address: topology.NatCandidateAddress, now_ns: core.TimeNs) CandidateGatheringPipelineError!void {
        try self.observe(.{ .kind = .host, .transport = .udp, .address = address, .priority = self.config.host_priority, .expires_at_ns = now_ns +| self.config.host_lifetime_ns }, now_ns);
    }

    pub fn observeServerReflexive(self: *CandidateGatheringPipeline, mapped: protocol.StunAddress, now_ns: core.TimeNs) CandidateGatheringPipelineError!void {
        try self.observe(.{ .kind = .server_reflexive, .transport = .udp, .address = candidateAddress(mapped), .priority = self.config.server_reflexive_priority, .expires_at_ns = now_ns +| self.config.server_reflexive_lifetime_ns }, now_ns);
    }

    pub fn observeRelay(self: *CandidateGatheringPipeline, allocation: topology.TurnAllocation, credentials: topology.NatCandidateCredentials, now_ns: core.TimeNs) CandidateGatheringPipelineError!void {
        if (allocation.expires_at_ns <= now_ns or credentials.expires_at_ns <= now_ns) return error.ExpiredCandidate;
        var candidate = topology.NatCandidate{ .kind = .relay, .transport = .udp, .address = candidateAddress(allocation.relay), .priority = self.config.relay_priority, .expires_at_ns = @min(allocation.expires_at_ns, now_ns +| self.config.relay_lifetime_ns), .credentials = credentials };
        if (candidate.credentials) |*value| value.expires_at_ns = @min(value.expires_at_ns, candidate.expires_at_ns);
        try self.observe(candidate, now_ns);
    }

    pub fn expire(self: *CandidateGatheringPipeline, now_ns: core.TimeNs) void {
        var index: usize = 0;
        while (index < self.candidates.items.len) {
            if (!topology.candidate_expired(self.candidates.items[index], now_ns)) {
                index += 1;
                continue;
            }
            _ = self.candidates.orderedRemove(index);
        }
    }

    pub fn list(self: *CandidateGatheringPipeline, output: []topology.NatCandidate, now_ns: core.TimeNs) CandidateGatheringPipelineError![]const topology.NatCandidate {
        self.expire(now_ns);
        if (output.len < self.candidates.items.len) return error.OutputTooSmall;
        sortCandidates(self.candidates.items);
        @memcpy(output[0..self.candidates.items.len], self.candidates.items);
        return output[0..self.candidates.items.len];
    }

    fn observe(self: *CandidateGatheringPipeline, candidate: topology.NatCandidate, now_ns: core.TimeNs) CandidateGatheringPipelineError!void {
        try topology.validate_nat_candidate(candidate, now_ns);
        self.expire(now_ns);
        for (self.candidates.items, 0..) |current, index| {
            if (!sameCandidate(current, candidate)) continue;
            if (candidate.priority >= current.priority) self.candidates.items[index] = candidate;
            return;
        }
        if (self.candidates.items.len == self.config.maximum_candidates) return error.CandidateCapacityExceeded;
        try self.candidates.append(self.allocator, candidate);
    }
};

fn candidateAddress(address: protocol.StunAddress) topology.NatCandidateAddress {
    return switch (address) {
        .ipv4 => |value| .{ .ipv4 = .{ .octets = value.octets, .port = value.port } },
        .ipv6 => |value| .{ .ipv6 = .{ .octets = value.octets, .port = value.port, .scope_id = 0 } },
    };
}

fn sameCandidate(first: topology.NatCandidate, second: topology.NatCandidate) bool {
    return first.kind == second.kind and first.transport == second.transport and std.meta.eql(first.address, second.address);
}

fn sortCandidates(values: []topology.NatCandidate) void {
    var index: usize = 1;
    while (index < values.len) : (index += 1) {
        const current = values[index];
        var destination = index;
        while (destination > 0 and before(current, values[destination - 1])) : (destination -= 1) values[destination] = values[destination - 1];
        values[destination] = current;
    }
}

fn before(first: topology.NatCandidate, second: topology.NatCandidate) bool {
    if (first.priority != second.priority) return first.priority > second.priority;
    return @intFromEnum(first.kind) < @intFromEnum(second.kind);
}

test "candidate gathering pipelines return stable deduplicated provider observations" {
    var pipeline = try CandidateGatheringPipeline.init(std.testing.allocator, .{ .maximum_candidates = 3, .host_lifetime_ns = 10, .server_reflexive_lifetime_ns = 20, .relay_lifetime_ns = 30 });
    defer pipeline.deinit();
    try pipeline.observeHost(.{ .ipv4 = .{ .octets = .{ 10, 0, 0, 1 }, .port = 4000 } }, 0);
    try pipeline.observeServerReflexive(.{ .ipv4 = .{ .octets = .{ 198, 51, 100, 1 }, .port = 5000 } }, 0);
    try pipeline.observeRelay(.{ .relay = .{ .ipv4 = .{ .octets = .{ 203, 0, 113, 1 }, .port = 6000 } }, .expires_at_ns = 25 }, .{ .username = "u", .password = "p", .expires_at_ns = 25 }, 0);
    try pipeline.observeHost(.{ .ipv4 = .{ .octets = .{ 10, 0, 0, 1 }, .port = 4000 } }, 1);
    var output: [3]topology.NatCandidate = undefined;
    const gathered = try pipeline.list(output[0..], 1);
    try std.testing.expectEqual(@as(usize, 3), gathered.len);
    try std.testing.expectEqual(topology.NatCandidateKind.relay, gathered[0].kind);
    try std.testing.expectEqual(topology.NatCandidateKind.server_reflexive, gathered[1].kind);
    try std.testing.expectEqual(topology.NatCandidateKind.host, gathered[2].kind);
    try std.testing.expectEqual(@as(usize, 2), (try pipeline.list(output[0..], 11)).len);
}

test "candidate gathering pipelines bound candidate storage and expired relay credentials" {
    var pipeline = try CandidateGatheringPipeline.init(std.testing.allocator, .{ .maximum_candidates = 1, .host_lifetime_ns = 10, .server_reflexive_lifetime_ns = 10, .relay_lifetime_ns = 10 });
    defer pipeline.deinit();
    try pipeline.observeHost(.{ .ipv4 = .{ .octets = .{ 1, 1, 1, 1 }, .port = 1 } }, 0);
    try std.testing.expectError(error.CandidateCapacityExceeded, pipeline.observeServerReflexive(.{ .ipv4 = .{ .octets = .{ 2, 2, 2, 2 }, .port = 2 } }, 0));
    try std.testing.expectError(error.ExpiredCandidate, pipeline.observeRelay(.{ .relay = .{ .ipv4 = .{ .octets = .{ 3, 3, 3, 3 }, .port = 3 } }, .expires_at_ns = 1 }, .{ .username = "u", .password = "p", .expires_at_ns = 1 }, 1));
}
