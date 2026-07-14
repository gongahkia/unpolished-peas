const std = @import("std");

const credential_filename = "guest-session.up";
const magic = "UPGS";
const version: u8 = 1;
const token_bytes = 32;
const encoded_bytes = magic.len + 1 + token_bytes * 2 + @sizeOf(i64) * 2;

pub const Token = struct {
    bytes: [token_bytes]u8,

    pub fn generate() Token {
        var token: Token = undefined;
        std.crypto.random.bytes(&token.bytes);
        return token;
    }

    pub fn hash(self: Token) [std.crypto.hash.sha2.Sha256.digest_length]u8 {
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&self.bytes, &digest, .{});
        return digest;
    }

    pub fn eql(self: Token, other: Token) bool {
        return std.crypto.timing_safe.eql([token_bytes]u8, self.bytes, other.bytes);
    }
};

pub const Credentials = struct {
    identity: Token,
    session: Token,
    issued_at_ms: i64,
    expires_at_ms: i64,

    pub fn active(self: Credentials, now_ms: i64) bool {
        return self.issued_at_ms <= now_ms and now_ms < self.expires_at_ms;
    }
};

pub const Store = struct {
    root: []const u8,

    pub fn init(root: []const u8) Store {
        return .{ .root = root };
    }

    pub fn save(self: Store, credentials: Credentials) !void {
        if (credentials.expires_at_ms <= credentials.issued_at_ms) return error.InvalidCredentials;
        var dir = try std.fs.openDirAbsolute(self.root, .{});
        defer dir.close();
        var encoded: [encoded_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &encoded);
        encode(&encoded, credentials);
        var write_buffer: [encoded_bytes]u8 = undefined;
        var file = try dir.atomicFile(credential_filename, .{ .mode = 0o600, .write_buffer = &write_buffer });
        defer file.deinit();
        try file.file_writer.interface.writeAll(&encoded);
        try file.finish();
    }

    pub fn loadReusable(self: Store, now_ms: i64) !?Credentials {
        var dir = try std.fs.openDirAbsolute(self.root, .{});
        defer dir.close();
        const source = dir.readFileAlloc(std.heap.page_allocator, credential_filename, encoded_bytes) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer {
            std.crypto.secureZero(u8, source);
            std.heap.page_allocator.free(source);
        }
        const credentials = try decode(source);
        if (credentials.active(now_ms)) return credentials;
        try dir.deleteFile(credential_filename);
        return null;
    }

    pub fn clear(self: Store) !void {
        var dir = try std.fs.openDirAbsolute(self.root, .{});
        defer dir.close();
        dir.deleteFile(credential_filename) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
};

fn encode(destination: *[encoded_bytes]u8, credentials: Credentials) void {
    @memcpy(destination[0..magic.len], magic);
    destination[magic.len] = version;
    @memcpy(destination[magic.len + 1 ..][0..token_bytes], &credentials.identity.bytes);
    @memcpy(destination[magic.len + 1 + token_bytes ..][0..token_bytes], &credentials.session.bytes);
    std.mem.writeInt(i64, destination[magic.len + 1 + token_bytes * 2 ..][0..@sizeOf(i64)], credentials.issued_at_ms, .little);
    std.mem.writeInt(i64, destination[magic.len + 1 + token_bytes * 2 + @sizeOf(i64) ..][0..@sizeOf(i64)], credentials.expires_at_ms, .little);
}

fn decode(source: []const u8) !Credentials {
    if (source.len != encoded_bytes or !std.mem.eql(u8, source[0..magic.len], magic) or source[magic.len] != version) return error.InvalidCredentialStore;
    var identity: Token = undefined;
    var session: Token = undefined;
    @memcpy(&identity.bytes, source[magic.len + 1 ..][0..token_bytes]);
    @memcpy(&session.bytes, source[magic.len + 1 + token_bytes ..][0..token_bytes]);
    const issued_at_ms = std.mem.readInt(i64, source[magic.len + 1 + token_bytes * 2 ..][0..@sizeOf(i64)], .little);
    const expires_at_ms = std.mem.readInt(i64, source[magic.len + 1 + token_bytes * 2 + @sizeOf(i64) ..][0..@sizeOf(i64)], .little);
    if (expires_at_ms <= issued_at_ms) return error.InvalidCredentialStore;
    return .{ .identity = identity, .session = session, .issued_at_ms = issued_at_ms, .expires_at_ms = expires_at_ms };
}

test "guest tokens are 256-bit and hash without retaining plaintext" {
    const first = Token.generate();
    const second = Token.generate();
    try std.testing.expectEqual(@as(usize, 32), first.bytes.len);
    try std.testing.expect(!first.eql(second));
    try std.testing.expect(!std.crypto.timing_safe.eql([32]u8, first.hash(), second.hash()));
}

test "guest credential store reuses valid credentials and deletes expired credentials" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const store = Store.init(root);
    const credentials = Credentials{ .identity = Token.generate(), .session = Token.generate(), .issued_at_ms = 100, .expires_at_ms = 200 };
    try store.save(credentials);
    const loaded = (try store.loadReusable(150)).?;
    try std.testing.expect(loaded.identity.eql(credentials.identity));
    try std.testing.expect(loaded.session.eql(credentials.session));
    try std.testing.expect(try store.loadReusable(200) == null);
    try std.testing.expect(try store.loadReusable(150) == null);
}
