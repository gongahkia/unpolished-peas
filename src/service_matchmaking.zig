const std = @import("std");
const guest = @import("guest_credentials.zig");
const lobby = @import("service_lobby.zig");
const up = @import("unpolished-peas");

pub const Config = struct { max_queue_entries: usize = 128, queue_timeout_ms: i64 = 30_000 };
pub const QueueState = enum { waiting, assigned, cancelled, expired };
pub const Request = struct { id: u64, lobby_id: u64, identity: [32]u8, joined_at_ms: i64, state: QueueState = .waiting, match_id: ?u64 = null };
pub const Assignment = struct { match_id: u64, host_identity: [32]u8, client_identity: [32]u8, route_token: [32]u8 };

pub const Service = struct { // owns bounded queue and assignment records; call deinit once.
    allocator: std.mem.Allocator,
    lobbies: *lobby.Service,
    config: Config,
    queue: std.ArrayListUnmanaged(Request) = .{},
    assignments: std.ArrayListUnmanaged(Assignment) = .{},
    next_request_id: u64 = 1,
    next_match_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator, lobbies: *lobby.Service, config: Config) !Service {
        if (config.max_queue_entries == 0 or config.max_queue_entries > 1_024 or config.queue_timeout_ms <= 0) return error.InvalidMatchmakingConfig;
        return .{ .allocator = allocator, .lobbies = lobbies, .config = config };
    }

    pub fn deinit(self: *Service) void {
        self.queue.deinit(self.allocator);
        self.assignments.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn enqueue(self: *Service, lobby_id: u64, credentials: guest.Credentials, now_ms: i64) !Request {
        const identity = credentials.identity.hash();
        if (!try self.lobbies.isActiveMember(lobby_id, credentials, now_ms)) return error.IneligibleMatchParticipant;
        self.expire(now_ms);
        for (self.queue.items) |request| if (request.lobby_id == lobby_id and std.crypto.timing_safe.eql([32]u8, request.identity, identity) and request.state != .cancelled and request.state != .expired) return request;
        if (self.queue.items.len >= self.config.max_queue_entries) return error.MatchQueueFull;
        const request = Request{ .id = self.next_request_id, .lobby_id = lobby_id, .identity = identity, .joined_at_ms = now_ms };
        self.next_request_id +%= 1;
        if (self.next_request_id == 0) self.next_request_id = 1;
        try self.queue.append(self.allocator, request);
        return request;
    }

    pub fn cancel(self: *Service, request_id: u64, credentials: guest.Credentials, now_ms: i64) !void {
        const request = self.findRequest(request_id) orelse return error.UnknownMatchRequest;
        if (!std.crypto.timing_safe.eql([32]u8, request.identity, credentials.identity.hash())) return error.MatchRequestForbidden;
        if (!credentials.active(now_ms)) return error.GuestSessionExpired;
        if (request.state == .assigned) return;
        if (request.state != .waiting) return error.MatchRequestUnavailable;
        request.state = .cancelled;
    }

    pub fn matchNext(self: *Service, now_ms: i64) !?Assignment {
        self.expire(now_ms);
        var first: ?usize = null;
        for (self.queue.items, 0..) |request, index| {
            if (request.state != .waiting) continue;
            if (first == null) {
                first = index;
                continue;
            }
            const host = &self.queue.items[first.?];
            const client = &self.queue.items[index];
            const assignment = Assignment{ .match_id = self.next_match_id, .host_identity = host.identity, .client_identity = client.identity, .route_token = guest.Token.generate().bytes };
            self.next_match_id +%= 1;
            if (self.next_match_id == 0) self.next_match_id = 1;
            try self.assignments.append(self.allocator, assignment);
            host.state = .assigned;
            host.match_id = assignment.match_id;
            client.state = .assigned;
            client.match_id = assignment.match_id;
            return assignment;
        }
        return null;
    }

    pub fn assignmentFor(self: *const Service, request_id: u64) ?Assignment {
        const request = self.findRequestConst(request_id) orelse return null;
        const match_id = request.match_id orelse return null;
        for (self.assignments.items) |assignment| if (assignment.match_id == match_id) return assignment;
        return null;
    }

    pub fn expire(self: *Service, now_ms: i64) void {
        for (self.queue.items) |*request| {
            if (request.state == .waiting and now_ms - request.joined_at_ms >= self.config.queue_timeout_ms) request.state = .expired;
        }
    }

    fn findRequest(self: *Service, id: u64) ?*Request {
        for (self.queue.items) |*request| if (request.id == id) return request;
        return null;
    }

    fn findRequestConst(self: *const Service, id: u64) ?*const Request {
        for (self.queue.items) |*request| if (request.id == id) return request;
        return null;
    }
};

test "matchmaking enforces queue capacity timeout cancellation and idempotence" {
    var fake = @import("service_provider.zig").FakeAdapter{};
    const provider = fake.provider();
    var lobbies = try lobby.Service.init(std.testing.allocator, provider, .{});
    defer lobbies.deinit();
    var matches = try Service.init(std.testing.allocator, &lobbies, .{ .max_queue_entries = 2, .queue_timeout_ms = 5 });
    defer matches.deinit();
    const first = try provider.issueGuestSession(.{ .now_ms = 1, .lifetime_ms = 100 });
    const second = try provider.issueGuestSession(.{ .now_ms = 1, .lifetime_ms = 100 });
    const third = try provider.issueGuestSession(.{ .now_ms = 1, .lifetime_ms = 100 });
    const first_lobby = try lobbies.create(first, 2, 100, 1);
    try lobbies.join(first_lobby.id, second, 1);
    const first_request = try matches.enqueue(first_lobby.id, first, 1);
    try std.testing.expectEqual(first_request.id, (try matches.enqueue(first_lobby.id, first, 1)).id);
    const second_request = try matches.enqueue(first_lobby.id, second, 1);
    try std.testing.expectError(error.MatchQueueFull, matches.enqueue(first_lobby.id, third, 1));
    try matches.cancel(second_request.id, second, 2);
    try std.testing.expect(try matches.matchNext(2) == null);
    matches.expire(6);
    try std.testing.expectEqual(QueueState.expired, matches.findRequestConst(first_request.id).?.state);
}

test "matched local lobby participants receive deterministic bootstrap assignment" {
    var fake = @import("service_provider.zig").FakeAdapter{};
    const provider = fake.provider();
    var lobbies = try lobby.Service.init(std.testing.allocator, provider, .{});
    defer lobbies.deinit();
    var matches = try Service.init(std.testing.allocator, &lobbies, .{});
    defer matches.deinit();
    const host = try provider.issueGuestSession(.{ .now_ms = 1, .lifetime_ms = 100 });
    const client = try provider.issueGuestSession(.{ .now_ms = 1, .lifetime_ms = 100 });
    const room = try lobbies.create(host, 2, 100, 1);
    try lobbies.join(room.id, client, 1);
    const host_request = try matches.enqueue(room.id, host, 1);
    _ = try matches.enqueue(room.id, client, 1);
    const assignment = (try matches.matchNext(1)).?;
    try std.testing.expectEqual(assignment.match_id, matches.assignmentFor(host_request.id).?.match_id);
    try std.testing.expect(!std.crypto.timing_safe.eql([32]u8, assignment.host_identity, assignment.client_identity));
    const authentication_token = std.mem.readInt(u64, assignment.route_token[0..8], .little) | 1;
    var host_endpoint = up.LoopbackTransport.init(std.testing.allocator, .{ .id = 1 });
    defer host_endpoint.deinit();
    var client_endpoint = up.LoopbackTransport.init(std.testing.allocator, .{ .id = 2 });
    defer client_endpoint.deinit();
    up.LoopbackTransport.pair(&host_endpoint, &client_endpoint);
    const host_identity = try up.NetIdentity.init(1);
    const client_identity = try up.NetIdentity.init(2);
    var host_peer = try up.P2pPeer.init(std.testing.allocator, .{ .local_identity = host_identity, .remote_identity = client_identity, .session_id = assignment.match_id, .authentication_token = authentication_token, .expires_at_ms = 100, .peer = .{ .id = 2 } });
    defer host_peer.deinit();
    var client_peer = try up.P2pPeer.init(std.testing.allocator, .{ .local_identity = client_identity, .remote_identity = host_identity, .session_id = assignment.match_id, .authentication_token = authentication_token, .expires_at_ms = 100, .peer = .{ .id = 1 } });
    defer client_peer.deinit();
    try host_peer.begin(host_endpoint.transport());
    try client_peer.begin(client_endpoint.transport());
    try host_peer.poll(host_endpoint.transport());
    try client_peer.poll(client_endpoint.transport());
    try host_peer.poll(host_endpoint.transport());
    try client_peer.poll(client_endpoint.transport());
    try client_peer.sendReliable(client_endpoint.transport(), "playable");
    try host_peer.poll(host_endpoint.transport());
    var received = host_peer.receive() orelse return error.TestExpectedEqual;
    defer received.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("playable", received.payload);
}
