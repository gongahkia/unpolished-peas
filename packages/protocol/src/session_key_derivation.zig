const std = @import("std");
const protection = @import("packet_protection.zig");
const psk = @import("psk_authentication.zig");

const hkdf = std.crypto.kdf.hkdf.HkdfSha256;
const key_domain = "minna-san/v1/session-packet-key";
const initiator_to_responder_label = "initiator-to-responder";
const responder_to_initiator_label = "responder-to-initiator";

pub const session_transcript_bytes: usize = hkdf.prk_length;
pub const SessionKeyDirection = enum(u8) { initiator_to_responder, responder_to_initiator };
pub const SessionKeyDerivationError = psk.PskAuthenticationError;
pub const SessionPacketKeys = struct {
    initiator_to_responder: protection.PacketProtectionKey,
    responder_to_initiator: protection.PacketProtectionKey,

    pub fn key(self: SessionPacketKeys, direction: SessionKeyDirection) protection.PacketProtectionKey {
        return switch (direction) {
            .initiator_to_responder => self.initiator_to_responder,
            .responder_to_initiator => self.responder_to_initiator,
        };
    }

    pub fn clear(self: *SessionPacketKeys) void {
        self.initiator_to_responder.clear();
        self.responder_to_initiator.clear();
    }
};

pub fn derive_session_packet_keys(key_material: []const u8, transcript: [session_transcript_bytes]u8) SessionKeyDerivationError!SessionPacketKeys {
    var key = try psk.PskKey.init(key_material);
    defer key.clear();
    var prk = hkdf.extract(&transcript, key.bytes[0..key.length]);
    defer std.crypto.secureZero(u8, &prk);
    return .{
        .initiator_to_responder = derive_packet_key(prk, initiator_to_responder_label),
        .responder_to_initiator = derive_packet_key(prk, responder_to_initiator_label),
    };
}

fn derive_packet_key(prk: [hkdf.prk_length]u8, comptime label: []const u8) protection.PacketProtectionKey {
    var info: [key_domain.len + label.len]u8 = undefined;
    @memcpy(info[0..key_domain.len], key_domain);
    @memcpy(info[key_domain.len..], label);
    var material: [protection.packet_protection_key_bytes + protection.packet_protection_nonce_prefix_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &material);
    hkdf.expand(&material, &info, prk);
    return protection.PacketProtectionKey.init(material[0..protection.packet_protection_key_bytes].*, material[protection.packet_protection_key_bytes..].*);
}

test "session key derivation matches authenticated transcripts and separates directions" {
    const key = [_]u8{5} ** 32;
    const transcript = [_]u8{7} ** session_transcript_bytes;
    var initiator = try derive_session_packet_keys(key[0..], transcript);
    defer initiator.clear();
    var responder = try derive_session_packet_keys(key[0..], transcript);
    defer responder.clear();
    try std.testing.expectEqual(initiator.initiator_to_responder, responder.initiator_to_responder);
    try std.testing.expectEqual(initiator.responder_to_initiator, responder.responder_to_initiator);
    try std.testing.expect(!std.mem.eql(u8, &initiator.initiator_to_responder.key, &initiator.responder_to_initiator.key));
    var changed = transcript;
    changed[0] +%= 1;
    var mismatched = try derive_session_packet_keys(key[0..], changed);
    defer mismatched.clear();
    try std.testing.expect(!std.mem.eql(u8, &initiator.initiator_to_responder.key, &mismatched.initiator_to_responder.key));
}

test "session key derivation zeroizes material and rejects invalid PSK input" {
    const key = [_]u8{8} ** 32;
    var keys = try derive_session_packet_keys(key[0..], .{9} ** session_transcript_bytes);
    keys.clear();
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** protection.packet_protection_key_bytes), &keys.initiator_to_responder.key);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** protection.packet_protection_nonce_prefix_bytes), &keys.responder_to_initiator.nonce_prefix);
    try std.testing.expectError(error.InvalidKeyLength, derive_session_packet_keys("short", .{0} ** session_transcript_bytes));
}
