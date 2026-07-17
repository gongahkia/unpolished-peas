const groups = @import("routed_peer_group.zig");

pub const PeerDiscoveryError = error{ InvalidRequest, OutputTooSmall, DiscoveryFailed, RendezvousFailed, SignalingFailed };

pub const DiscoveryCandidate = struct {
    peer: groups.PeerGroupPeerId,
    path: groups.PeerGroupPath,
};

pub const DiscoveryRequest = struct {
    group: groups.PeerGroupId,
    requester: groups.PeerGroupPeerId,
    maximum_candidates: usize,
};

pub const RendezvousRequest = struct {
    group: groups.PeerGroupId,
    requester: groups.PeerGroupPeerId,
};

pub const SignalingMessage = struct {
    group: groups.PeerGroupId,
    sender: groups.PeerGroupPeerId,
    recipient: groups.PeerGroupPeerId,
    payload: []const u8,
};

pub const PeerDiscoveryHooks = struct {
    context: *anyopaque,
    discover_fn: *const fn (*anyopaque, DiscoveryRequest, []DiscoveryCandidate) PeerDiscoveryError!usize,
    rendezvous_fn: *const fn (*anyopaque, RendezvousRequest) PeerDiscoveryError!void,
    signal_fn: *const fn (*anyopaque, SignalingMessage) PeerDiscoveryError!void,

    pub fn discover(self: PeerDiscoveryHooks, request: DiscoveryRequest, output: []DiscoveryCandidate) PeerDiscoveryError!usize {
        if (request.group == 0 or request.requester == 0 or request.maximum_candidates > output.len) return error.InvalidRequest;
        const count = try self.discover_fn(self.context, request, output);
        if (count > request.maximum_candidates) return error.OutputTooSmall;
        return count;
    }

    pub fn rendezvous(self: PeerDiscoveryHooks, request: RendezvousRequest) PeerDiscoveryError!void {
        if (request.group == 0 or request.requester == 0) return error.InvalidRequest;
        return self.rendezvous_fn(self.context, request);
    }

    pub fn signal(self: PeerDiscoveryHooks, message: SignalingMessage) PeerDiscoveryError!void {
        if (message.group == 0 or message.sender == 0 or message.recipient == 0 or message.sender == message.recipient) return error.InvalidRequest;
        return self.signal_fn(self.context, message);
    }
};

test "peer discovery hooks preserve bounded consumer supplied integration" {
    const Fixture = struct {
        rendezvous_count: usize = 0,
        payload: []const u8 = "",
        fn hooks(self: *@This()) PeerDiscoveryHooks {
            return .{ .context = self, .discover_fn = discover, .rendezvous_fn = rendezvous, .signal_fn = signal };
        }
        fn discover(_: *anyopaque, _: DiscoveryRequest, output: []DiscoveryCandidate) PeerDiscoveryError!usize {
            output[0] = .{ .peer = 2, .path = .{ .direct = 1 } };
            return 1;
        }
        fn rendezvous(context: *anyopaque, _: RendezvousRequest) PeerDiscoveryError!void {
            @as(*@This(), @ptrCast(@alignCast(context))).rendezvous_count += 1;
        }
        fn signal(context: *anyopaque, message: SignalingMessage) PeerDiscoveryError!void {
            @as(*@This(), @ptrCast(@alignCast(context))).payload = message.payload;
        }
    };
    var fixture = Fixture{};
    const hooks = fixture.hooks();
    var candidates: [1]DiscoveryCandidate = undefined;
    try @import("std").testing.expectEqual(@as(usize, 1), try hooks.discover(.{ .group = 1, .requester = 1, .maximum_candidates = 1 }, candidates[0..]));
    try hooks.rendezvous(.{ .group = 1, .requester = 1 });
    try hooks.signal(.{ .group = 1, .sender = 1, .recipient = 2, .payload = "offer" });
    try @import("std").testing.expectEqual(@as(usize, 1), fixture.rendezvous_count);
    try @import("std").testing.expectEqualStrings("offer", fixture.payload);
    try @import("std").testing.expectError(error.OutputTooSmall, hooks.discover(.{ .group = 1, .requester = 1, .maximum_candidates = 0 }, candidates[0..]));
    try @import("std").testing.expectError(error.InvalidRequest, hooks.discover(.{ .group = 0, .requester = 1, .maximum_candidates = 0 }, candidates[0..]));
    try @import("std").testing.expectError(error.InvalidRequest, hooks.signal(.{ .group = 1, .sender = 1, .recipient = 1, .payload = "" }));
}
