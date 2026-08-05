const std = @import("std");
const psk = @import("psk_authentication.zig");
const key_derivation = @import("session_key_derivation.zig");

const sha256 = std.crypto.hash.sha2.Sha256;
const transcript_domain = "minna-san/v1/secure-datagram-handshake";
const client_proof_label = "client-proof";
const server_proof_label = "server-proof";

pub const secure_datagram_handshake_frame_max_bytes: usize = 1 + @sizeOf(u64) + 2 * psk.psk_challenge_nonce_bytes;
pub const SecureDatagramHandshakeRole = enum(u8) { initiator, responder };
pub const SecureDatagramHandshakeState = enum(u8) { idle, awaiting_challenge, awaiting_proof, awaiting_accept, authenticated, rejected, timed_out };
pub const SecureDatagramHandshakeMessageKind = enum(u8) { hello = 1, challenge = 2, proof = 3, accept = 4 };
pub const SecureDatagramHandshakeError = psk.PskAuthenticationError || key_derivation.SessionKeyDerivationError || error{ InvalidConfiguration, DeadlineOverflow, DeadlineExpired, UnexpectedMessage, SessionMismatch, TranscriptMismatch, HandshakeNotAuthenticated, MalformedMessage, OutputTooSmall };

pub const SecureDatagramHandshakeConfig = struct {
    role: SecureDatagramHandshakeRole,
    session_id: u64,
    timeout_ns: u64,

    pub fn validate(self: SecureDatagramHandshakeConfig) SecureDatagramHandshakeError!void {
        if (self.session_id == 0 or self.timeout_ns == 0) return error.InvalidConfiguration;
    }
};

pub const SecureDatagramHello = struct {
    session_id: u64,
    client_nonce: [psk.psk_challenge_nonce_bytes]u8,
};
pub const SecureDatagramChallenge = struct {
    session_id: u64,
    client_nonce: [psk.psk_challenge_nonce_bytes]u8,
    server_nonce: [psk.psk_challenge_nonce_bytes]u8,
};
pub const SecureDatagramProof = struct {
    session_id: u64,
    tag: [psk.psk_proof_bytes]u8,
};
pub const SecureDatagramHandshakeMessage = union(SecureDatagramHandshakeMessageKind) {
    hello: SecureDatagramHello,
    challenge: SecureDatagramChallenge,
    proof: SecureDatagramProof,
    accept: SecureDatagramProof,
};

pub const SecureDatagramHandshake = struct {
    config: SecureDatagramHandshakeConfig,
    authenticator: psk.PskAuthenticator,
    state: SecureDatagramHandshakeState = .idle,
    client_nonce: ?[psk.psk_challenge_nonce_bytes]u8 = null,
    server_nonce: ?[psk.psk_challenge_nonce_bytes]u8 = null,
    deadline_ns: ?u64 = null,

    pub fn init(config: SecureDatagramHandshakeConfig, key_material: []const u8) SecureDatagramHandshakeError!SecureDatagramHandshake {
        try config.validate();
        return .{ .config = config, .authenticator = try psk.PskAuthenticator.init(key_material) };
    }

    pub fn deinit(self: *SecureDatagramHandshake) void {
        self.authenticator.deinit();
        self.* = undefined;
    }

    pub fn begin(self: *SecureDatagramHandshake, now_ns: u64) SecureDatagramHandshakeError!SecureDatagramHandshakeMessage {
        if (self.config.role != .initiator or self.state != .idle) return error.UnexpectedMessage;
        try self.beginDeadline(now_ns);
        var nonce: [psk.psk_challenge_nonce_bytes]u8 = undefined;
        std.crypto.random.bytes(&nonce);
        self.client_nonce = nonce;
        self.state = .awaiting_challenge;
        return .{ .hello = .{ .session_id = self.config.session_id, .client_nonce = nonce } };
    }

    pub fn receive(self: *SecureDatagramHandshake, message: SecureDatagramHandshakeMessage, now_ns: u64) SecureDatagramHandshakeError!?SecureDatagramHandshakeMessage {
        if (self.expire(now_ns)) return error.DeadlineExpired;
        return switch (message) {
            .hello => |hello| self.receiveHello(hello, now_ns),
            .challenge => |challenge| self.receiveChallenge(challenge),
            .proof => |proof| self.receiveProof(proof),
            .accept => |accept| self.receiveAccept(accept),
        };
    }

    pub fn poll(self: *SecureDatagramHandshake, now_ns: u64) bool {
        return self.expire(now_ns);
    }

    pub fn nextDeadline(self: *const SecureDatagramHandshake) ?u64 {
        return if (is_pending(self.state)) self.deadline_ns else null;
    }

    pub fn transcriptHash(self: *const SecureDatagramHandshake) ?[sha256.digest_length]u8 {
        const client_nonce = self.client_nonce orelse return null;
        const server_nonce = self.server_nonce orelse return null;
        return transcript_hash(self.config.session_id, client_nonce, server_nonce, "transcript");
    }

    pub fn applicationPayload(self: *const SecureDatagramHandshake, payload: []const u8) ?[]const u8 {
        return if (self.state == .authenticated) payload else null;
    }

    pub fn derivePacketKeys(self: *const SecureDatagramHandshake, key_material: []const u8) SecureDatagramHandshakeError!key_derivation.SessionPacketKeys {
        if (self.state != .authenticated) return error.HandshakeNotAuthenticated;
        return key_derivation.derive_session_packet_keys(key_material, self.transcriptHash() orelse return error.HandshakeNotAuthenticated);
    }

    fn receiveHello(self: *SecureDatagramHandshake, hello: SecureDatagramHello, now_ns: u64) SecureDatagramHandshakeError!?SecureDatagramHandshakeMessage {
        if (self.config.role != .responder or self.state != .idle) return self.reject(error.UnexpectedMessage);
        if (hello.session_id != self.config.session_id) return self.reject(error.SessionMismatch);
        try self.beginDeadline(now_ns);
        var nonce: [psk.psk_challenge_nonce_bytes]u8 = undefined;
        std.crypto.random.bytes(&nonce);
        self.client_nonce = hello.client_nonce;
        self.server_nonce = nonce;
        self.state = .awaiting_proof;
        return .{ .challenge = .{ .session_id = self.config.session_id, .client_nonce = hello.client_nonce, .server_nonce = nonce } };
    }

    fn receiveChallenge(self: *SecureDatagramHandshake, challenge: SecureDatagramChallenge) SecureDatagramHandshakeError!?SecureDatagramHandshakeMessage {
        if (self.config.role != .initiator or self.state != .awaiting_challenge) return self.reject(error.UnexpectedMessage);
        if (challenge.session_id != self.config.session_id) return self.reject(error.SessionMismatch);
        const client_nonce = self.client_nonce orelse return self.reject(error.UnexpectedMessage);
        if (!std.crypto.timing_safe.eql([psk.psk_challenge_nonce_bytes]u8, client_nonce, challenge.client_nonce)) return self.reject(error.TranscriptMismatch);
        self.server_nonce = challenge.server_nonce;
        const proof = self.authenticator.prove(proof_challenge(self.config.session_id, client_nonce, challenge.server_nonce, client_proof_label));
        self.state = .awaiting_accept;
        return .{ .proof = .{ .session_id = self.config.session_id, .tag = proof.tag } };
    }

    fn receiveProof(self: *SecureDatagramHandshake, proof: SecureDatagramProof) SecureDatagramHandshakeError!?SecureDatagramHandshakeMessage {
        if (self.config.role != .responder or self.state != .awaiting_proof) return self.reject(error.UnexpectedMessage);
        if (proof.session_id != self.config.session_id) return self.reject(error.SessionMismatch);
        const client_nonce = self.client_nonce orelse return self.reject(error.UnexpectedMessage);
        const server_nonce = self.server_nonce orelse return self.reject(error.UnexpectedMessage);
        const challenge = proof_challenge(self.config.session_id, client_nonce, server_nonce, client_proof_label);
        self.authenticator.begin(challenge) catch return self.reject(error.UnexpectedMessage);
        self.authenticator.verify_pending(.{ .tag = proof.tag }) catch return self.reject(error.AuthenticationFailed);
        const accept = self.authenticator.prove(proof_challenge(self.config.session_id, client_nonce, server_nonce, server_proof_label));
        self.state = .authenticated;
        return .{ .accept = .{ .session_id = self.config.session_id, .tag = accept.tag } };
    }

    fn receiveAccept(self: *SecureDatagramHandshake, accept: SecureDatagramProof) SecureDatagramHandshakeError!?SecureDatagramHandshakeMessage {
        if (self.config.role != .initiator or self.state != .awaiting_accept) return self.reject(error.UnexpectedMessage);
        if (accept.session_id != self.config.session_id) return self.reject(error.SessionMismatch);
        const client_nonce = self.client_nonce orelse return self.reject(error.UnexpectedMessage);
        const server_nonce = self.server_nonce orelse return self.reject(error.UnexpectedMessage);
        const challenge = proof_challenge(self.config.session_id, client_nonce, server_nonce, server_proof_label);
        self.authenticator.begin(challenge) catch return self.reject(error.UnexpectedMessage);
        self.authenticator.verify_pending(.{ .tag = accept.tag }) catch return self.reject(error.AuthenticationFailed);
        self.state = .authenticated;
        return null;
    }

    fn beginDeadline(self: *SecureDatagramHandshake, now_ns: u64) SecureDatagramHandshakeError!void {
        self.deadline_ns = std.math.add(u64, now_ns, self.config.timeout_ns) catch return error.DeadlineOverflow;
    }

    fn expire(self: *SecureDatagramHandshake, now_ns: u64) bool {
        const deadline = self.deadline_ns orelse return false;
        if (!is_pending(self.state) or now_ns < deadline) return false;
        self.state = .timed_out;
        return true;
    }

    fn reject(self: *SecureDatagramHandshake, err: SecureDatagramHandshakeError) SecureDatagramHandshakeError {
        self.state = .rejected;
        return err;
    }
};

pub fn encode_secure_datagram_handshake(message: SecureDatagramHandshakeMessage, output: []u8) SecureDatagramHandshakeError![]u8 {
    const required = switch (message) {
        .hello => 1 + @sizeOf(u64) + psk.psk_challenge_nonce_bytes,
        .proof, .accept => 1 + @sizeOf(u64) + psk.psk_proof_bytes,
        .challenge => secure_datagram_handshake_frame_max_bytes,
    };
    if (output.len < required) return error.OutputTooSmall;
    switch (message) {
        .hello => |hello| {
            output[0] = @intFromEnum(SecureDatagramHandshakeMessageKind.hello);
            std.mem.writeInt(u64, output[1..9], hello.session_id, .big);
            @memcpy(output[9..required], &hello.client_nonce);
        },
        .challenge => |challenge| {
            output[0] = @intFromEnum(SecureDatagramHandshakeMessageKind.challenge);
            std.mem.writeInt(u64, output[1..9], challenge.session_id, .big);
            @memcpy(output[9..][0..psk.psk_challenge_nonce_bytes], &challenge.client_nonce);
            @memcpy(output[9 + psk.psk_challenge_nonce_bytes .. required], &challenge.server_nonce);
        },
        .proof => |proof| write_proof(.proof, proof, output[0..required]),
        .accept => |accept| write_proof(.accept, accept, output[0..required]),
    }
    return output[0..required];
}

pub fn decode_secure_datagram_handshake(input: []const u8) SecureDatagramHandshakeError!SecureDatagramHandshakeMessage {
    if (input.len < 1 + @sizeOf(u64)) return error.MalformedMessage;
    const kind: SecureDatagramHandshakeMessageKind = std.meta.intToEnum(SecureDatagramHandshakeMessageKind, input[0]) catch return error.MalformedMessage;
    const session_id = std.mem.readInt(u64, input[1..9], .big);
    return switch (kind) {
        .hello => .{ .hello = .{ .session_id = session_id, .client_nonce = try decode_hello_nonce(input) } },
        .challenge => .{ .challenge = .{ .session_id = session_id, .client_nonce = try decode_first_challenge_nonce(input), .server_nonce = try decode_second_nonce(input) } },
        .proof => .{ .proof = try decode_proof(input, session_id) },
        .accept => .{ .accept = try decode_proof(input, session_id) },
    };
}

fn is_pending(state: SecureDatagramHandshakeState) bool {
    return state == .awaiting_challenge or state == .awaiting_proof or state == .awaiting_accept;
}

fn proof_challenge(session_id: u64, client_nonce: [psk.psk_challenge_nonce_bytes]u8, server_nonce: [psk.psk_challenge_nonce_bytes]u8, label: []const u8) psk.PskChallenge {
    return .{ .session_id = session_id, .nonce = transcript_hash(session_id, client_nonce, server_nonce, label) };
}

fn transcript_hash(session_id: u64, client_nonce: [psk.psk_challenge_nonce_bytes]u8, server_nonce: [psk.psk_challenge_nonce_bytes]u8, label: []const u8) [sha256.digest_length]u8 {
    var hasher = sha256.init(.{});
    hasher.update(transcript_domain);
    hasher.update(label);
    var session: [@sizeOf(u64)]u8 = undefined;
    std.mem.writeInt(u64, session[0..], session_id, .big);
    hasher.update(&session);
    hasher.update(&client_nonce);
    hasher.update(&server_nonce);
    var result: [sha256.digest_length]u8 = undefined;
    hasher.final(&result);
    return result;
}

fn write_proof(kind: SecureDatagramHandshakeMessageKind, proof: SecureDatagramProof, output: []u8) void {
    output[0] = @intFromEnum(kind);
    std.mem.writeInt(u64, output[1..9], proof.session_id, .big);
    @memcpy(output[9..], &proof.tag);
}

fn decode_hello_nonce(input: []const u8) SecureDatagramHandshakeError![psk.psk_challenge_nonce_bytes]u8 {
    if (input.len != 1 + @sizeOf(u64) + psk.psk_challenge_nonce_bytes) return error.MalformedMessage;
    var nonce: [psk.psk_challenge_nonce_bytes]u8 = undefined;
    @memcpy(&nonce, input[9..]);
    return nonce;
}

fn decode_first_challenge_nonce(input: []const u8) SecureDatagramHandshakeError![psk.psk_challenge_nonce_bytes]u8 {
    if (input.len != secure_datagram_handshake_frame_max_bytes) return error.MalformedMessage;
    var nonce: [psk.psk_challenge_nonce_bytes]u8 = undefined;
    @memcpy(&nonce, input[9..][0..psk.psk_challenge_nonce_bytes]);
    return nonce;
}

fn decode_second_nonce(input: []const u8) SecureDatagramHandshakeError![psk.psk_challenge_nonce_bytes]u8 {
    if (input.len != secure_datagram_handshake_frame_max_bytes) return error.MalformedMessage;
    var nonce: [psk.psk_challenge_nonce_bytes]u8 = undefined;
    @memcpy(&nonce, input[9 + psk.psk_challenge_nonce_bytes ..]);
    return nonce;
}

fn decode_proof(input: []const u8, session_id: u64) SecureDatagramHandshakeError!SecureDatagramProof {
    if (input.len != 1 + @sizeOf(u64) + psk.psk_proof_bytes) return error.MalformedMessage;
    var tag: [psk.psk_proof_bytes]u8 = undefined;
    @memcpy(&tag, input[9..]);
    return .{ .session_id = session_id, .tag = tag };
}

test "secure datagram handshakes authenticate transcripts before delivering application payloads" {
    const key = [_]u8{7} ** 32;
    var initiator = try SecureDatagramHandshake.init(.{ .role = .initiator, .session_id = 9, .timeout_ns = 10 }, key[0..]);
    defer initiator.deinit();
    var responder = try SecureDatagramHandshake.init(.{ .role = .responder, .session_id = 9, .timeout_ns = 10 }, key[0..]);
    defer responder.deinit();
    try std.testing.expect(initiator.applicationPayload("payload") == null);
    try std.testing.expectError(error.HandshakeNotAuthenticated, initiator.derivePacketKeys(key[0..]));
    const hello = try initiator.begin(1);
    const challenge = (try responder.receive(hello, 1)).?;
    const proof = (try initiator.receive(challenge, 1)).?;
    const accept = (try responder.receive(proof, 1)).?;
    try std.testing.expect((try initiator.receive(accept, 1)) == null);
    try std.testing.expectEqual(SecureDatagramHandshakeState.authenticated, initiator.state);
    try std.testing.expectEqual(SecureDatagramHandshakeState.authenticated, responder.state);
    try std.testing.expectEqual(initiator.transcriptHash().?, responder.transcriptHash().?);
    var initiator_keys = try initiator.derivePacketKeys(key[0..]);
    defer initiator_keys.clear();
    var responder_keys = try responder.derivePacketKeys(key[0..]);
    defer responder_keys.clear();
    try std.testing.expectEqual(initiator_keys, responder_keys);
    try std.testing.expectEqualStrings("payload", initiator.applicationPayload("payload").?);
}

test "secure datagram handshakes reject tampered transcripts and expire pending sessions" {
    const key = [_]u8{3} ** 32;
    var initiator = try SecureDatagramHandshake.init(.{ .role = .initiator, .session_id = 4, .timeout_ns = 5 }, key[0..]);
    defer initiator.deinit();
    var responder = try SecureDatagramHandshake.init(.{ .role = .responder, .session_id = 4, .timeout_ns = 5 }, key[0..]);
    defer responder.deinit();
    const hello = try initiator.begin(1);
    var challenge = (try responder.receive(hello, 1)).?;
    challenge.challenge.client_nonce[0] +%= 1;
    try std.testing.expectError(error.TranscriptMismatch, initiator.receive(challenge, 1));
    try std.testing.expectEqual(SecureDatagramHandshakeState.rejected, initiator.state);
    try std.testing.expect(initiator.applicationPayload("payload") == null);
    var timed_out = try SecureDatagramHandshake.init(.{ .role = .initiator, .session_id = 5, .timeout_ns = 5 }, key[0..]);
    defer timed_out.deinit();
    _ = try timed_out.begin(1);
    try std.testing.expect(timed_out.poll(6));
    try std.testing.expectEqual(SecureDatagramHandshakeState.timed_out, timed_out.state);
    try std.testing.expect(timed_out.applicationPayload("payload") == null);
}

test "secure datagram handshake frames round trip and reject malformed input" {
    const message = SecureDatagramHandshakeMessage{ .challenge = .{ .session_id = 8, .client_nonce = .{1} ** psk.psk_challenge_nonce_bytes, .server_nonce = .{2} ** psk.psk_challenge_nonce_bytes } };
    var storage: [secure_datagram_handshake_frame_max_bytes]u8 = undefined;
    const encoded = try encode_secure_datagram_handshake(message, storage[0..]);
    const decoded = try decode_secure_datagram_handshake(encoded);
    try std.testing.expectEqual(message, decoded);
    try std.testing.expectError(error.MalformedMessage, decode_secure_datagram_handshake(encoded[0 .. encoded.len - 1]));
}
