const std = @import("std");
const guest = @import("guest_credentials.zig");
const provider = @import("service_provider.zig");

pub const Status = enum { open, closed, expired };
pub const Config = struct { max_lobbies: usize = 64, max_members: u16 = 64 };
pub const Lobby = struct { id: u64, owner: [32]u8, status: Status, max_members: u16, expires_at_ms: i64 };
pub const InspectorState = struct { open_lobbies: usize = 0, active_members: usize = 0, expired_lobbies: usize = 0 };
const Membership = struct { lobby_id: u64, identity: [32]u8, joined_at_ms: i64, left_at_ms: ?i64 = null };

pub const Service = struct { // owns bounded lobby and membership records; call deinit once.
    allocator: std.mem.Allocator,
    provider: provider.Provider,
    config: Config,
    lobbies: std.ArrayListUnmanaged(Lobby) = .{},
    memberships: std.ArrayListUnmanaged(Membership) = .{},
    next_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator, service_provider: provider.Provider, config: Config) !Service {
        if (config.max_lobbies == 0 or config.max_lobbies > 1_024 or config.max_members == 0 or config.max_members > 64) return error.InvalidLobbyConfig;
        return .{ .allocator = allocator, .provider = service_provider, .config = config };
    }

    pub fn deinit(self: *Service) void {
        self.lobbies.deinit(self.allocator);
        self.memberships.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn create(self: *Service, credentials: guest.Credentials, max_members: u16, expires_at_ms: i64, now_ms: i64) !Lobby {
        const identity = try self.authenticate(credentials, now_ms);
        self.expire(now_ms);
        if (max_members == 0 or max_members > self.config.max_members or expires_at_ms <= now_ms or self.lobbies.items.len >= self.config.max_lobbies) return error.InvalidLobbyRequest;
        const lobby = Lobby{ .id = self.next_id, .owner = identity, .status = .open, .max_members = max_members, .expires_at_ms = expires_at_ms };
        self.next_id +%= 1;
        if (self.next_id == 0) self.next_id = 1;
        try self.lobbies.append(self.allocator, lobby);
        errdefer _ = self.lobbies.pop();
        try self.memberships.append(self.allocator, .{ .lobby_id = lobby.id, .identity = identity, .joined_at_ms = now_ms });
        return lobby;
    }

    pub fn join(self: *Service, lobby_id: u64, credentials: guest.Credentials, now_ms: i64) !void {
        const identity = try self.authenticate(credentials, now_ms);
        self.expire(now_ms);
        const lobby = self.findLobby(lobby_id) orelse return error.UnknownLobby;
        if (lobby.status != .open) return error.LobbyUnavailable;
        if (self.activeMembership(lobby_id, identity) != null) return;
        if (self.memberCount(lobby_id) >= lobby.max_members) return error.LobbyFull;
        try self.memberships.append(self.allocator, .{ .lobby_id = lobby_id, .identity = identity, .joined_at_ms = now_ms });
    }

    pub fn leave(self: *Service, lobby_id: u64, credentials: guest.Credentials, now_ms: i64) !void {
        const identity = try self.authenticate(credentials, now_ms);
        self.expire(now_ms);
        const member = self.activeMembership(lobby_id, identity) orelse return error.NotLobbyMember;
        member.left_at_ms = now_ms;
    }

    pub fn disconnect(self: *Service, lobby_id: u64, credentials: guest.Credentials, now_ms: i64) !void {
        try self.leave(lobby_id, credentials, now_ms);
    }

    pub fn isActiveMember(self: *Service, lobby_id: u64, credentials: guest.Credentials, now_ms: i64) !bool {
        const identity = try self.authenticate(credentials, now_ms);
        self.expire(now_ms);
        return self.activeMembership(lobby_id, identity) != null;
    }

    pub fn inspectorState(self: *const Service, now_ms: i64) InspectorState {
        var state = InspectorState{};
        for (self.lobbies.items) |lobby| switch (lobby.status) {
            .open => {
                if (now_ms < lobby.expires_at_ms) state.open_lobbies += 1 else state.expired_lobbies += 1;
            },
            .expired => state.expired_lobbies += 1,
            .closed => {},
        };
        for (self.memberships.items) |member| {
            const lobby = self.findLobby(member.lobby_id) orelse continue;
            if (member.left_at_ms == null and lobby.status == .open and now_ms < lobby.expires_at_ms) state.active_members += 1;
        }
        return state;
    }

    pub fn expire(self: *Service, now_ms: i64) void {
        for (self.lobbies.items) |*lobby| {
            if (lobby.status == .open and now_ms >= lobby.expires_at_ms) lobby.status = .expired;
        }
    }

    fn authenticate(self: *Service, credentials: guest.Credentials, now_ms: i64) ![32]u8 {
        if (!credentials.active(now_ms)) return error.GuestSessionExpired;
        if (try self.provider.validateGuestSession(credentials.session) != .active) return error.GuestSessionRejected;
        return credentials.identity.hash();
    }

    fn findLobby(self: *const Service, id: u64) ?*Lobby {
        for (self.lobbies.items) |*lobby| if (lobby.id == id) return lobby;
        return null;
    }

    fn activeMembership(self: *Service, lobby_id: u64, identity: [32]u8) ?*Membership {
        for (self.memberships.items) |*member| if (member.lobby_id == lobby_id and member.left_at_ms == null and std.crypto.timing_safe.eql([32]u8, member.identity, identity)) return member;
        return null;
    }

    fn memberCount(self: *Service, lobby_id: u64) u16 {
        var count: u16 = 0;
        for (self.memberships.items) |member| {
            if (member.lobby_id == lobby_id and member.left_at_ms == null) count += 1;
        }
        return count;
    }
};

test "guest lobbies enforce membership bounds and disconnect cleanup" {
    var fake = provider.FakeAdapter{};
    const service_provider = fake.provider();
    var service = try Service.init(std.testing.allocator, service_provider, .{});
    defer service.deinit();
    const owner = try service_provider.issueGuestSession(.{ .now_ms = 1, .lifetime_ms = 100 });
    const member = try service_provider.issueGuestSession(.{ .now_ms = 1, .lifetime_ms = 100 });
    const lobby = try service.create(owner, 2, 50, 2);
    try service.join(lobby.id, member, 2);
    try std.testing.expectEqual(@as(usize, 2), service.inspectorState(2).active_members);
    try std.testing.expectError(error.LobbyFull, service.join(lobby.id, (try service_provider.issueGuestSession(.{ .now_ms = 2, .lifetime_ms = 10 })), 2));
    try service.disconnect(lobby.id, member, 3);
    try std.testing.expectEqual(@as(usize, 1), service.inspectorState(3).active_members);
}

test "lobby expiration updates the client inspector snapshot" {
    var fake = provider.FakeAdapter{};
    const service_provider = fake.provider();
    var service = try Service.init(std.testing.allocator, service_provider, .{});
    defer service.deinit();
    const owner = try service_provider.issueGuestSession(.{ .now_ms = 1, .lifetime_ms = 100 });
    const lobby = try service.create(owner, 1, 5, 2);
    try std.testing.expectEqual(@as(usize, 1), service.inspectorState(2).open_lobbies);
    service.expire(5);
    try std.testing.expectEqual(@as(usize, 1), service.inspectorState(5).expired_lobbies);
    try std.testing.expectError(error.LobbyUnavailable, service.join(lobby.id, owner, 5));
}
