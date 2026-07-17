const std = @import("std");

const hmac = std.crypto.auth.hmac.sha2.HmacSha256;
const psk_domain = "minna-san/v1/psk-challenge";

pub const min_psk_bytes: usize = 16;
pub const max_psk_bytes: usize = 64;
pub const psk_challenge_nonce_bytes: usize = 32;
pub const psk_proof_bytes: usize = hmac.mac_length;
pub const PskAuthenticationError = error{ InvalidKeyLength, ChallengeAlreadyPending, NoPendingChallenge, AuthenticationFailed };

pub const PskKey = struct {
    bytes: [max_psk_bytes]u8 = .{0} ** max_psk_bytes,
    length: usize,

    pub fn init(material: []const u8) PskAuthenticationError!PskKey {
        if (material.len < min_psk_bytes or material.len > max_psk_bytes) return error.InvalidKeyLength;
        var key = PskKey{ .length = material.len };
        @memcpy(key.bytes[0..material.len], material);
        return key;
    }

    pub fn clear(self: *PskKey) void {
        std.crypto.secureZero(u8, &self.bytes);
        self.length = 0;
    }

    fn slice(self: PskKey) []const u8 {
        return self.bytes[0..self.length];
    }
};

pub const PskChallenge = struct {
    session_id: u64,
    nonce: [psk_challenge_nonce_bytes]u8,
};

pub const PskProof = struct {
    tag: [psk_proof_bytes]u8,
};

pub const PskAuthenticator = struct {
    key: PskKey,
    pending: ?PskChallenge = null,

    pub fn init(material: []const u8) PskAuthenticationError!PskAuthenticator {
        return .{ .key = try PskKey.init(material) };
    }

    pub fn deinit(self: *PskAuthenticator) void {
        self.key.clear();
        self.pending = null;
    }

    pub fn prove(self: PskAuthenticator, challenge: PskChallenge) PskProof {
        return .{ .tag = mac(self.key, challenge) };
    }

    pub fn begin(self: *PskAuthenticator, challenge: PskChallenge) PskAuthenticationError!void {
        if (self.pending != null) return error.ChallengeAlreadyPending;
        self.pending = challenge;
    }

    pub fn verify_pending(self: *PskAuthenticator, proof: PskProof) PskAuthenticationError!void {
        const challenge = self.pending orelse return error.NoPendingChallenge;
        var expected = mac(self.key, challenge);
        const valid = std.crypto.timing_safe.eql([psk_proof_bytes]u8, expected, proof.tag);
        std.crypto.secureZero(u8, &expected);
        self.pending = null;
        if (!valid) return error.AuthenticationFailed;
    }
};

fn mac(key: PskKey, challenge: PskChallenge) [psk_proof_bytes]u8 {
    var context = hmac.init(key.slice());
    context.update(psk_domain);
    var session: [8]u8 = undefined;
    std.mem.writeInt(u64, session[0..], challenge.session_id, .big);
    context.update(session[0..]);
    context.update(&challenge.nonce);
    var result: [psk_proof_bytes]u8 = undefined;
    context.final(&result);
    return result;
}

test "PSK challenges authenticate with owned keys and one-use verification" {
    var material = [_]u8{7} ** 32;
    var client = try PskAuthenticator.init(material[0..]);
    defer client.deinit();
    var server = try PskAuthenticator.init(material[0..]);
    defer server.deinit();
    material[0] = 9;
    const challenge = PskChallenge{ .session_id = 4, .nonce = [_]u8{3} ** psk_challenge_nonce_bytes };
    try server.begin(challenge);
    try server.verify_pending(client.prove(challenge));
    try std.testing.expectError(error.NoPendingChallenge, server.verify_pending(client.prove(challenge)));
}

test "PSK challenges reject invalid keys tampering and challenge reuse" {
    try std.testing.expectError(error.InvalidKeyLength, PskAuthenticator.init("short"));
    const material = [_]u8{1} ** min_psk_bytes;
    var client = try PskAuthenticator.init(material[0..]);
    defer client.deinit();
    var server = try PskAuthenticator.init(material[0..]);
    defer server.deinit();
    const challenge = PskChallenge{ .session_id = 1, .nonce = [_]u8{2} ** psk_challenge_nonce_bytes };
    try server.begin(challenge);
    try std.testing.expectError(error.ChallengeAlreadyPending, server.begin(challenge));
    var proof = client.prove(challenge);
    proof.tag[0] +%= 1;
    try std.testing.expectError(error.AuthenticationFailed, server.verify_pending(proof));
    try std.testing.expectError(error.NoPendingChallenge, server.verify_pending(client.prove(challenge)));
    client.deinit();
    try std.testing.expectEqual(@as(usize, 0), client.key.length);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** max_psk_bytes), client.key.bytes[0..]);
}
