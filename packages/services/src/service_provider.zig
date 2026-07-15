const std = @import("std");
const guest = @import("guest_credentials.zig");

const max_session_lifetime_ms: i64 = 24 * 60 * 60 * 1_000;

pub const Error = error{
    InvalidRequest,
    InvalidResponse,
    Unavailable,
};

pub const SessionRequest = struct {
    now_ms: i64,
    lifetime_ms: i64 = 60 * 60 * 1_000,
};

pub const SessionStatus = enum {
    active,
    rejected,
};

pub const Provider = struct {
    context: *anyopaque,
    issue_guest_session_fn: *const fn (context: *anyopaque, request: SessionRequest) Error!guest.Credentials,
    validate_guest_session_fn: *const fn (context: *anyopaque, session: guest.Token) Error!SessionStatus,

    pub fn issueGuestSession(self: Provider, request: SessionRequest) Error!guest.Credentials {
        return self.issue_guest_session_fn(self.context, request);
    }

    pub fn validateGuestSession(self: Provider, session: guest.Token) Error!SessionStatus {
        return self.validate_guest_session_fn(self.context, session);
    }
};

pub const FakeAdapter = struct {
    credentials: [64]?guest.Credentials = [_]?guest.Credentials{null} ** 64,
    failure: ?Error = null,

    pub fn provider(self: *FakeAdapter) Provider {
        return .{ .context = self, .issue_guest_session_fn = issue, .validate_guest_session_fn = validate };
    }

    fn issue(context: *anyopaque, request: SessionRequest) Error!guest.Credentials {
        const self: *FakeAdapter = @ptrCast(@alignCast(context));
        if (self.failure) |failure| return failure;
        const expires_at_ms = try requestExpiry(request);
        const credentials = guest.Credentials{
            .identity = guest.Token.generate(),
            .session = guest.Token.generate(),
            .issued_at_ms = request.now_ms,
            .expires_at_ms = expires_at_ms,
        };
        for (&self.credentials) |*slot| {
            if (slot.* != null) continue;
            slot.* = credentials;
            return credentials;
        }
        return error.Unavailable;
    }

    fn validate(context: *anyopaque, session: guest.Token) Error!SessionStatus {
        const self: *FakeAdapter = @ptrCast(@alignCast(context));
        if (self.failure) |failure| return failure;
        for (self.credentials) |maybe| {
            const credentials = maybe orelse continue;
            if (credentials.session.eql(session)) return .active;
        }
        return .rejected;
    }
};

pub const LocalPostgresAdapter = struct {
    allocator: std.mem.Allocator,
    database_url: []u8,

    pub fn init(allocator: std.mem.Allocator, database_url: []const u8) Error!LocalPostgresAdapter {
        if (database_url.len == 0) return error.InvalidRequest;
        const owned_url = allocator.dupe(u8, database_url) catch return error.Unavailable;
        return .{ .allocator = allocator, .database_url = owned_url };
    }

    pub fn deinit(self: *LocalPostgresAdapter) void {
        self.allocator.free(self.database_url);
        self.* = undefined;
    }

    pub fn provider(self: *LocalPostgresAdapter) Provider {
        return .{ .context = self, .issue_guest_session_fn = issue, .validate_guest_session_fn = validate };
    }

    fn issue(context: *anyopaque, request: SessionRequest) Error!guest.Credentials {
        const self: *LocalPostgresAdapter = @ptrCast(@alignCast(context));
        const expires_at_ms = try requestExpiry(request);
        const identity = guest.Token.generate();
        const session = guest.Token.generate();
        const identity_id = uuidFromToken(identity);
        const session_id = uuidFromToken(session);
        const identity_hash = identity.hash();
        const session_hash = session.hash();
        const identity_hash_hex = hexDigest(identity_hash);
        const session_hash_hex = hexDigest(session_hash);
        const query = std.fmt.allocPrint(
            self.allocator,
            "SELECT service_issue_guest_session('{s}', decode('{s}', 'hex'), CURRENT_TIMESTAMP + interval '{d} milliseconds', '{s}', decode('{s}', 'hex'), CURRENT_TIMESTAMP + interval '{d} milliseconds');",
            .{ identity_id, &identity_hash_hex, request.lifetime_ms, session_id, &session_hash_hex, request.lifetime_ms },
        ) catch return error.Unavailable;
        defer self.allocator.free(query);
        const output = try self.execute(query);
        defer self.allocator.free(output);
        if (std.mem.trim(u8, output, " \t\r\n").len != 0) return error.InvalidResponse;
        return .{ .identity = identity, .session = session, .issued_at_ms = request.now_ms, .expires_at_ms = expires_at_ms };
    }

    fn validate(context: *anyopaque, session: guest.Token) Error!SessionStatus {
        const self: *LocalPostgresAdapter = @ptrCast(@alignCast(context));
        const session_hash = session.hash();
        const session_hash_hex = hexDigest(session_hash);
        const query = std.fmt.allocPrint(
            self.allocator,
            "SELECT CASE WHEN EXISTS (SELECT 1 FROM service_validate_guest_session(decode('{s}', 'hex'))) THEN 'active' ELSE 'rejected' END;",
            .{&session_hash_hex},
        ) catch return error.Unavailable;
        defer self.allocator.free(query);
        const output = try self.execute(query);
        defer self.allocator.free(output);
        const status = std.mem.trim(u8, output, " \t\r\n");
        if (std.mem.eql(u8, status, "active")) return .active;
        if (std.mem.eql(u8, status, "rejected")) return .rejected;
        return error.InvalidResponse;
    }

    fn execute(self: *LocalPostgresAdapter, query: []const u8) Error![]u8 {
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "psql", "-X", "-v", "ON_ERROR_STOP=1", "-Atq", self.database_url, "-c", query },
            .max_output_bytes = 64 * 1024,
        }) catch return error.Unavailable;
        defer self.allocator.free(result.stderr);
        if (result.term != .Exited or result.term.Exited != 0) {
            self.allocator.free(result.stdout);
            return error.Unavailable;
        }
        return result.stdout;
    }
};

fn requestExpiry(request: SessionRequest) Error!i64 {
    if (request.now_ms < 0 or request.lifetime_ms <= 0 or request.lifetime_ms > max_session_lifetime_ms) return error.InvalidRequest;
    return std.math.add(i64, request.now_ms, request.lifetime_ms) catch error.InvalidRequest;
}

fn uuidFromToken(token: guest.Token) [36]u8 {
    const digits = "0123456789abcdef";
    var raw = token.bytes;
    raw[6] = (raw[6] & 0x0f) | 0x40;
    raw[8] = (raw[8] & 0x3f) | 0x80;
    var uuid: [36]u8 = undefined;
    var write_index: usize = 0;
    for (raw[0..16], 0..) |byte, index| {
        if (index == 4 or index == 6 or index == 8 or index == 10) {
            uuid[write_index] = '-';
            write_index += 1;
        }
        uuid[write_index] = digits[byte >> 4];
        uuid[write_index + 1] = digits[byte & 0x0f];
        write_index += 2;
    }
    return uuid;
}

fn hexDigest(digest: [std.crypto.hash.sha2.Sha256.digest_length]u8) [std.crypto.hash.sha2.Sha256.digest_length * 2]u8 {
    const digits = "0123456789abcdef";
    var encoded: [std.crypto.hash.sha2.Sha256.digest_length * 2]u8 = undefined;
    for (digest, 0..) |byte, index| {
        encoded[index * 2] = digits[byte >> 4];
        encoded[index * 2 + 1] = digits[byte & 0x0f];
    }
    return encoded;
}

test "engine client runs against a fake provider with bounded failures" {
    var fake = FakeAdapter{};
    const provider = fake.provider();
    const credentials = try provider.issueGuestSession(.{ .now_ms = 100, .lifetime_ms = 10 });
    try std.testing.expect(credentials.active(105));
    try std.testing.expectEqual(SessionStatus.active, try provider.validateGuestSession(credentials.session));
    try std.testing.expectEqual(SessionStatus.rejected, try provider.validateGuestSession(guest.Token.generate()));
    fake.failure = error.Unavailable;
    try std.testing.expectError(error.Unavailable, provider.issueGuestSession(.{ .now_ms = 100 }));
    try std.testing.expectError(error.Unavailable, provider.validateGuestSession(credentials.session));
    fake.failure = null;
    try std.testing.expectError(error.InvalidRequest, provider.issueGuestSession(.{ .now_ms = 100, .lifetime_ms = 0 }));
}

test "local PostgreSQL adapter issues and validates a guest session" {
    const database_url = std.process.getEnvVarOwned(std.testing.allocator, "UP_SERVICES_DATABASE_URL") catch return error.SkipZigTest;
    defer std.testing.allocator.free(database_url);
    var local = try LocalPostgresAdapter.init(std.testing.allocator, database_url);
    defer local.deinit();
    const provider = local.provider();
    const credentials = try provider.issueGuestSession(.{ .now_ms = @intCast(std.time.milliTimestamp()), .lifetime_ms = 60_000 });
    try std.testing.expectEqual(SessionStatus.active, try provider.validateGuestSession(credentials.session));
}
