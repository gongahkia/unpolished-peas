const std = @import("std");
const core = @import("minna-san-core");
const public_key_authentication = @import("public_key_authentication.zig");

const signaling_domain = "minna-san/v1/signed-signaling";

pub const signed_signaling_version: u8 = 1;
pub const signed_signaling_max_payload_bytes: usize = 1024;
pub const signed_signaling_header_bytes: usize = 70;
pub const signed_signaling_signature_bytes: usize = public_key_authentication.public_key_signature_bytes;
pub const SignedSignalingError = error{
    InvalidCredentials,
    InvalidEnvelope,
    BufferTooSmall,
    MalformedEnvelope,
    UnsupportedVersion,
    UnknownMessageKind,
    CredentialMismatch,
    SessionIntentMismatch,
    ExpiredMessage,
    IdentityMismatch,
    InvalidSignature,
    ReplayDetected,
    ReplayCapacityExceeded,
};

pub const SignalingMessageKind = enum(u8) { offer = 1, answer = 2, candidate = 3, cancellation = 4 };

pub const SignalingApplicationCredentials = struct {
    application_id: u64,
    identity: public_key_authentication.PublicKeyIdentity,

    pub fn validate(self: SignalingApplicationCredentials) SignedSignalingError!void {
        if (self.application_id == 0) return error.InvalidCredentials;
        _ = self.identity.public_key() catch return error.InvalidCredentials;
    }
};

pub const SignalingEnvelope = struct {
    kind: SignalingMessageKind,
    session_intent: u64,
    expires_at_ns: core.TimeNs,
    nonce: u64,
    payload: []const u8,
};

pub const SignedSignalingMessage = struct {
    kind: SignalingMessageKind,
    application_id: u64,
    session_intent: u64,
    expires_at_ns: core.TimeNs,
    nonce: u64,
    signer_identity: [public_key_authentication.public_key_identity_bytes]u8,
    payload: []const u8,
};

pub const SignalingVerificationConfig = struct {
    application_id: u64,
    session_intent: u64,
    expected_signer_identity: [public_key_authentication.public_key_identity_bytes]u8,

    pub fn validate(self: SignalingVerificationConfig) SignedSignalingError!void {
        if (self.application_id == 0) return error.InvalidCredentials;
        _ = std.crypto.sign.Ed25519.PublicKey.fromBytes(self.expected_signer_identity) catch return error.InvalidCredentials;
    }
};

pub const SignalingReplayEntry = struct {
    application_id: u64,
    session_intent: u64,
    nonce: u64,
    expires_at_ns: core.TimeNs,
};

pub const SignedSignalingReplayRegistry = struct {
    entries: []SignalingReplayEntry,
    len: usize = 0,

    pub fn init(entries: []SignalingReplayEntry) SignedSignalingReplayRegistry {
        return .{ .entries = entries };
    }

    pub fn verify_and_remember(self: *SignedSignalingReplayRegistry, config: SignalingVerificationConfig, wire: []const u8, now_ns: core.TimeNs) SignedSignalingError!SignedSignalingMessage {
        const message = try verify_signed_signaling_message(config, wire, now_ns);
        self.prune(now_ns);
        for (self.entries[0..self.len]) |entry| {
            if (entry.application_id == message.application_id and entry.session_intent == message.session_intent and entry.nonce == message.nonce) return error.ReplayDetected;
        }
        if (self.len == self.entries.len) return error.ReplayCapacityExceeded;
        self.entries[self.len] = .{
            .application_id = message.application_id,
            .session_intent = message.session_intent,
            .nonce = message.nonce,
            .expires_at_ns = message.expires_at_ns,
        };
        self.len += 1;
        return message;
    }

    pub fn prune(self: *SignedSignalingReplayRegistry, now_ns: core.TimeNs) void {
        var write_index: usize = 0;
        for (self.entries[0..self.len]) |entry| {
            if (entry.expires_at_ns > now_ns) {
                self.entries[write_index] = entry;
                write_index += 1;
            }
        }
        self.len = write_index;
    }
};

pub fn encode_signed_signaling_message(credentials: SignalingApplicationCredentials, envelope: SignalingEnvelope, output: []u8) SignedSignalingError![]const u8 {
    try credentials.validate();
    if (envelope.expires_at_ns == 0 or envelope.payload.len > signed_signaling_max_payload_bytes) return error.InvalidEnvelope;
    const total = signed_signaling_header_bytes + envelope.payload.len + signed_signaling_signature_bytes;
    if (output.len < total) return error.BufferTooSmall;
    output[0] = signed_signaling_version;
    output[1] = @intFromEnum(envelope.kind);
    output[2] = 0;
    output[3] = 0;
    std.mem.writeInt(u64, output[4..12], credentials.application_id, .big);
    std.mem.writeInt(u64, output[12..20], envelope.session_intent, .big);
    std.mem.writeInt(u64, output[20..28], envelope.expires_at_ns, .big);
    std.mem.writeInt(u64, output[28..36], envelope.nonce, .big);
    std.mem.writeInt(u16, output[36..38], @intCast(envelope.payload.len), .big);
    const identity = credentials.identity.public_key() catch return error.InvalidCredentials;
    @memcpy(output[38..signed_signaling_header_bytes], &identity);
    @memcpy(output[signed_signaling_header_bytes..][0..envelope.payload.len], envelope.payload);
    var signing_bytes: [signaling_domain.len + signed_signaling_header_bytes + signed_signaling_max_payload_bytes]u8 = undefined;
    const signed = output[0 .. signed_signaling_header_bytes + envelope.payload.len];
    const message = signing_message(signed, &signing_bytes);
    const signature = credentials.identity.sign_message(message) catch return error.InvalidSignature;
    @memcpy(output[signed.len..][0..signed_signaling_signature_bytes], &signature);
    return output[0..total];
}

pub fn verify_signed_signaling_message(config: SignalingVerificationConfig, wire: []const u8, now_ns: core.TimeNs) SignedSignalingError!SignedSignalingMessage {
    try config.validate();
    if (wire.len < signed_signaling_header_bytes + signed_signaling_signature_bytes) return error.MalformedEnvelope;
    if (wire[0] != signed_signaling_version) return error.UnsupportedVersion;
    if (wire[2] != 0 or wire[3] != 0) return error.MalformedEnvelope;
    const kind = std.meta.intToEnum(SignalingMessageKind, wire[1]) catch return error.UnknownMessageKind;
    const payload_len = std.mem.readInt(u16, wire[36..38], .big);
    if (payload_len > signed_signaling_max_payload_bytes) return error.MalformedEnvelope;
    const signed_len = signed_signaling_header_bytes + @as(usize, payload_len);
    if (wire.len != signed_len + signed_signaling_signature_bytes) return error.MalformedEnvelope;
    const application_id = std.mem.readInt(u64, wire[4..12], .big);
    if (application_id != config.application_id) return error.CredentialMismatch;
    const session_intent = std.mem.readInt(u64, wire[12..20], .big);
    if (session_intent != config.session_intent) return error.SessionIntentMismatch;
    const expires_at_ns = std.mem.readInt(u64, wire[20..28], .big);
    if (expires_at_ns <= now_ns) return error.ExpiredMessage;
    var signer_identity: [public_key_authentication.public_key_identity_bytes]u8 = undefined;
    @memcpy(&signer_identity, wire[38..signed_signaling_header_bytes]);
    if (!std.crypto.timing_safe.eql([public_key_authentication.public_key_identity_bytes]u8, signer_identity, config.expected_signer_identity)) return error.IdentityMismatch;
    var signature: [signed_signaling_signature_bytes]u8 = undefined;
    @memcpy(&signature, wire[signed_len..]);
    var signing_bytes: [signaling_domain.len + signed_signaling_header_bytes + signed_signaling_max_payload_bytes]u8 = undefined;
    const message = signing_message(wire[0..signed_len], &signing_bytes);
    public_key_authentication.verify_public_key_signature(signer_identity, message, signature) catch return error.InvalidSignature;
    return .{
        .kind = kind,
        .application_id = application_id,
        .session_intent = session_intent,
        .expires_at_ns = expires_at_ns,
        .nonce = std.mem.readInt(u64, wire[28..36], .big),
        .signer_identity = signer_identity,
        .payload = wire[signed_signaling_header_bytes..signed_len],
    };
}

fn signing_message(signed: []const u8, output: []u8) []const u8 {
    @memcpy(output[0..signaling_domain.len], signaling_domain);
    @memcpy(output[signaling_domain.len..][0..signed.len], signed);
    return output[0 .. signaling_domain.len + signed.len];
}

test "signed signaling authenticates versioned offer answer candidate and cancellation envelopes" {
    var identity = try public_key_authentication.PublicKeyIdentity.init([_]u8{7} ** std.crypto.sign.Ed25519.KeyPair.seed_length);
    defer identity.clear();
    const credentials = SignalingApplicationCredentials{ .application_id = 19, .identity = identity };
    const config = SignalingVerificationConfig{ .application_id = 19, .session_intent = 44, .expected_signer_identity = try identity.public_key() };
    const kinds = [_]SignalingMessageKind{ .offer, .answer, .candidate, .cancellation };
    for (kinds, 0..) |kind, index| {
        var wire: [signed_signaling_header_bytes + 4 + signed_signaling_signature_bytes]u8 = undefined;
        const encoded = try encode_signed_signaling_message(credentials, .{ .kind = kind, .session_intent = 44, .expires_at_ns = 100, .nonce = @intCast(index), .payload = "test" }, &wire);
        const decoded = try verify_signed_signaling_message(config, encoded, 99);
        try std.testing.expectEqual(kind, decoded.kind);
        try std.testing.expectEqualStrings("test", decoded.payload);
    }
}

test "signed signaling rejects modified expired mismatched and replayed envelopes before use" {
    var identity = try public_key_authentication.PublicKeyIdentity.init([_]u8{8} ** std.crypto.sign.Ed25519.KeyPair.seed_length);
    defer identity.clear();
    const credentials = SignalingApplicationCredentials{ .application_id = 5, .identity = identity };
    const config = SignalingVerificationConfig{ .application_id = 5, .session_intent = 6, .expected_signer_identity = try identity.public_key() };
    var wire: [signed_signaling_header_bytes + 9 + signed_signaling_signature_bytes]u8 = undefined;
    const encoded = try encode_signed_signaling_message(credentials, .{ .kind = .candidate, .session_intent = 6, .expires_at_ns = 10, .nonce = 2, .payload = "candidate" }, &wire);
    var registry_entries: [1]SignalingReplayEntry = undefined;
    var registry = SignedSignalingReplayRegistry.init(&registry_entries);
    const candidate = try registry.verify_and_remember(config, encoded, 9);
    try std.testing.expectEqualStrings("candidate", candidate.payload);
    try std.testing.expectError(error.ReplayDetected, registry.verify_and_remember(config, encoded, 9));
    try std.testing.expectError(error.ExpiredMessage, verify_signed_signaling_message(config, encoded, 10));
    var modified = wire;
    modified[signed_signaling_header_bytes] +%= 1;
    try std.testing.expectError(error.InvalidSignature, verify_signed_signaling_message(config, modified[0..encoded.len], 9));
    const wrong_session = SignalingVerificationConfig{ .application_id = 5, .session_intent = 7, .expected_signer_identity = try identity.public_key() };
    try std.testing.expectError(error.SessionIntentMismatch, verify_signed_signaling_message(wrong_session, encoded, 9));
}
