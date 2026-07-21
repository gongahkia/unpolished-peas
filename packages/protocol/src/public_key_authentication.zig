const std = @import("std");

const ed25519 = std.crypto.sign.Ed25519;
const x25519 = std.crypto.dh.X25519;
const hkdf = std.crypto.kdf.hkdf.HkdfSha256;
const signature_domain = "minna-san/v1/public-key-hello";
const session_domain = "minna-san/v1/public-key-session";

pub const public_key_identity_bytes: usize = ed25519.PublicKey.encoded_length;
pub const public_key_signature_bytes: usize = ed25519.Signature.encoded_length;
pub const public_key_session_key_bytes: usize = x25519.shared_length;
pub const PublicKeyRole = enum(u8) { initiator, responder };
pub const PublicKeyAuthenticationError = error{ InvalidIdentityKey, InvalidEphemeralKey, InvalidSignature, IdentityMismatch, SessionMismatch, UnexpectedPeerRole };

pub const PublicKeyIdentity = struct {
    seed: [ed25519.KeyPair.seed_length]u8,

    pub fn init(seed: [ed25519.KeyPair.seed_length]u8) PublicKeyAuthenticationError!PublicKeyIdentity {
        _ = ed25519.KeyPair.generateDeterministic(seed) catch return error.InvalidIdentityKey;
        return .{ .seed = seed };
    }

    pub fn generate() PublicKeyIdentity {
        var seed: [ed25519.KeyPair.seed_length]u8 = undefined;
        std.crypto.random.bytes(&seed);
        return .{ .seed = seed };
    }

    pub fn public_key(self: PublicKeyIdentity) PublicKeyAuthenticationError![public_key_identity_bytes]u8 {
        return (try self.key_pair()).public_key.toBytes();
    }

    pub fn clear(self: *PublicKeyIdentity) void {
        std.crypto.secureZero(u8, &self.seed);
    }

    fn key_pair(self: PublicKeyIdentity) PublicKeyAuthenticationError!ed25519.KeyPair {
        return ed25519.KeyPair.generateDeterministic(self.seed) catch return error.InvalidIdentityKey;
    }

    pub fn sign_message(self: PublicKeyIdentity, message: []const u8) PublicKeyAuthenticationError![public_key_signature_bytes]u8 {
        const signature = (try self.key_pair()).sign(message, null) catch return error.InvalidSignature;
        return signature.toBytes();
    }
};

pub const PublicKeyHello = struct {
    session_id: u64,
    role: PublicKeyRole,
    identity_key: [public_key_identity_bytes]u8,
    ephemeral_key: [x25519.public_length]u8,
    signature: [public_key_signature_bytes]u8,
};

pub const PublicKeyKeyExchange = struct {
    identity: PublicKeyIdentity,
    ephemeral: x25519.KeyPair,
    session_id: u64,
    role: PublicKeyRole,

    pub fn init(identity: PublicKeyIdentity, session_id: u64, role: PublicKeyRole) PublicKeyKeyExchange {
        return .{ .identity = identity, .ephemeral = x25519.KeyPair.generate(), .session_id = session_id, .role = role };
    }

    pub fn deinit(self: *PublicKeyKeyExchange) void {
        self.identity.clear();
        std.crypto.secureZero(u8, &self.ephemeral.secret_key);
    }

    pub fn hello(self: PublicKeyKeyExchange) PublicKeyAuthenticationError!PublicKeyHello {
        var result = PublicKeyHello{
            .session_id = self.session_id,
            .role = self.role,
            .identity_key = try self.identity.public_key(),
            .ephemeral_key = self.ephemeral.public_key,
            .signature = .{0} ** public_key_signature_bytes,
        };
        const message = hello_message(result);
        result.signature = try self.identity.sign_message(&message);
        return result;
    }

    pub fn derive_session_key(self: PublicKeyKeyExchange, expected_peer_identity: [public_key_identity_bytes]u8, peer: PublicKeyHello) PublicKeyAuthenticationError![public_key_session_key_bytes]u8 {
        try verify_public_key_hello(self.session_id, opposite_role(self.role), expected_peer_identity, peer);
        var shared = x25519.scalarmult(self.ephemeral.secret_key, peer.ephemeral_key) catch return error.InvalidEphemeralKey;
        defer std.crypto.secureZero(u8, &shared);
        const local = try self.hello();
        return derive_key(local, peer, shared);
    }
};

pub fn verify_public_key_hello(session_id: u64, expected_role: PublicKeyRole, expected_identity: [public_key_identity_bytes]u8, hello: PublicKeyHello) PublicKeyAuthenticationError!void {
    if (hello.session_id != session_id) return error.SessionMismatch;
    if (hello.role != expected_role) return error.UnexpectedPeerRole;
    if (!std.crypto.timing_safe.eql([public_key_identity_bytes]u8, hello.identity_key, expected_identity)) return error.IdentityMismatch;
    const message = hello_message(hello);
    try verify_public_key_signature(hello.identity_key, &message, hello.signature);
}

pub fn verify_public_key_signature(identity_key: [public_key_identity_bytes]u8, message: []const u8, signature_bytes: [public_key_signature_bytes]u8) PublicKeyAuthenticationError!void {
    const identity = ed25519.PublicKey.fromBytes(identity_key) catch return error.InvalidIdentityKey;
    const signature = ed25519.Signature.fromBytes(signature_bytes);
    signature.verify(message, identity) catch return error.InvalidSignature;
}

fn opposite_role(role: PublicKeyRole) PublicKeyRole {
    return switch (role) {
        .initiator => .responder,
        .responder => .initiator,
    };
}

fn hello_message(hello: PublicKeyHello) [signature_domain.len + 8 + 1 + public_key_identity_bytes + x25519.public_length]u8 {
    var message: [signature_domain.len + 8 + 1 + public_key_identity_bytes + x25519.public_length]u8 = undefined;
    var offset: usize = 0;
    @memcpy(message[offset..][0..signature_domain.len], signature_domain);
    offset += signature_domain.len;
    std.mem.writeInt(u64, message[offset..][0..8], hello.session_id, .big);
    offset += 8;
    message[offset] = @intFromEnum(hello.role);
    offset += 1;
    @memcpy(message[offset..][0..public_key_identity_bytes], &hello.identity_key);
    offset += public_key_identity_bytes;
    @memcpy(message[offset..][0..x25519.public_length], &hello.ephemeral_key);
    return message;
}

fn derive_key(local: PublicKeyHello, peer: PublicKeyHello, shared: [x25519.shared_length]u8) [public_key_session_key_bytes]u8 {
    const initiator, const responder = if (local.role == .initiator) .{ local, peer } else .{ peer, local };
    var context: [session_domain.len + 8 + 2 * (public_key_identity_bytes + x25519.public_length)]u8 = undefined;
    var offset: usize = 0;
    @memcpy(context[offset..][0..session_domain.len], session_domain);
    offset += session_domain.len;
    std.mem.writeInt(u64, context[offset..][0..8], initiator.session_id, .big);
    offset += 8;
    inline for (.{ initiator, responder }) |hello| {
        @memcpy(context[offset..][0..public_key_identity_bytes], &hello.identity_key);
        offset += public_key_identity_bytes;
        @memcpy(context[offset..][0..x25519.public_length], &hello.ephemeral_key);
        offset += x25519.public_length;
    }
    var prk = hkdf.extract(session_domain, &shared);
    defer std.crypto.secureZero(u8, &prk);
    var key: [public_key_session_key_bytes]u8 = undefined;
    hkdf.expand(&key, &context, prk);
    return key;
}

test "public-key authentication derives matching authenticated ephemeral session keys" {
    var initiator_identity = try PublicKeyIdentity.init([_]u8{1} ** ed25519.KeyPair.seed_length);
    defer initiator_identity.clear();
    var responder_identity = try PublicKeyIdentity.init([_]u8{2} ** ed25519.KeyPair.seed_length);
    defer responder_identity.clear();
    var initiator = PublicKeyKeyExchange.init(initiator_identity, 41, .initiator);
    defer initiator.deinit();
    var responder = PublicKeyKeyExchange.init(responder_identity, 41, .responder);
    defer responder.deinit();
    const initiator_hello = try initiator.hello();
    const responder_hello = try responder.hello();
    const initiator_key = try initiator.derive_session_key(try responder_identity.public_key(), responder_hello);
    const responder_key = try responder.derive_session_key(try initiator_identity.public_key(), initiator_hello);
    try std.testing.expectEqual(initiator_key, responder_key);
}

test "public-key authentication rejects invalid peer bindings" {
    const initiator_identity = try PublicKeyIdentity.init([_]u8{3} ** ed25519.KeyPair.seed_length);
    const responder_identity = try PublicKeyIdentity.init([_]u8{4} ** ed25519.KeyPair.seed_length);
    var initiator = PublicKeyKeyExchange.init(initiator_identity, 8, .initiator);
    defer initiator.deinit();
    var responder = PublicKeyKeyExchange.init(responder_identity, 8, .responder);
    defer responder.deinit();
    const expected_peer = try responder_identity.public_key();
    const hello = try responder.hello();
    var tampered = hello;
    tampered.signature[0] +%= 1;
    try std.testing.expectError(error.InvalidSignature, initiator.derive_session_key(expected_peer, tampered));
    try std.testing.expectError(error.IdentityMismatch, initiator.derive_session_key(try initiator_identity.public_key(), hello));
    var wrong_session = hello;
    wrong_session.session_id = 9;
    try std.testing.expectError(error.SessionMismatch, initiator.derive_session_key(expected_peer, wrong_session));
    var wrong_role = hello;
    wrong_role.role = .initiator;
    try std.testing.expectError(error.UnexpectedPeerRole, initiator.derive_session_key(expected_peer, wrong_role));
    responder.ephemeral.public_key = .{0} ** x25519.public_length;
    const invalid_ephemeral = try responder.hello();
    try std.testing.expectError(error.InvalidEphemeralKey, initiator.derive_session_key(expected_peer, invalid_ephemeral));
}
