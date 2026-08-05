const std = @import("std");
const packet = @import("packet_envelope.zig");
const protection = @import("packet_protection.zig");
const psk = @import("psk_authentication.zig");
const public_key = @import("public_key_authentication.zig");
const replay = @import("replay_window.zig");
const rotation = @import("key_rotation.zig");
const components = @import("security_components.zig");
const fragmentation = @import("message_fragmentation.zig");

fn bytes(comptime hex: []const u8) [hex.len / 2]u8 {
    var output: [hex.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(output[0..], hex) catch unreachable;
    return output;
}

test "security vectors fix PSK public-key and AEAD output" {
    const material = [_]u8{1} ** psk.min_psk_bytes;
    var client = try psk.PskAuthenticator.init(material[0..]);
    defer client.deinit();
    const challenge = psk.PskChallenge{ .session_id = 4, .nonce = [_]u8{3} ** psk.psk_challenge_nonce_bytes };
    try std.testing.expectEqual(bytes("a4d4a72e93748071ea4b4025ed3510dc3b5125f4608ae26c8251c67f00185e6d"), client.prove(challenge).tag);

    var identity = try public_key.PublicKeyIdentity.init(bytes("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"));
    defer identity.clear();
    try std.testing.expectEqual(bytes("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"), try identity.public_key());

    const key = protection.PacketProtectionKey.init([_]u8{5} ** protection.packet_protection_key_bytes, [_]u8{7} ** protection.packet_protection_nonce_prefix_bytes);
    var sender = protection.PacketProtector.init(key);
    defer sender.deinit();
    var storage: [protection.packet_protection_frame_header_bytes + 7 + protection.packet_protection_tag_bytes]u8 = undefined;
    const expected_frame = bytes("00000000000000008637e7eca665628c49bd3aa4228c9564b6613d4259b784");
    try std.testing.expectEqualSlices(u8, &expected_frame, try sender.seal("message", storage[0..]));
}

test "security vectors fix replay rotation and downgrade outcomes" {
    var window = try replay.ReplayWindow.init(.{ .window_size = 4 });
    const sequences = [_]u64{ 8, 10, 9, 10, 6 };
    const expected = [_]replay.ReplayClassification{ .accepted, .accepted, .accepted, .duplicate, .too_old };
    for (sequences, expected) |sequence, classification| try std.testing.expectEqual(classification, window.observe(sequence));

    const secret = [_]u8{9} ** protection.packet_protection_key_bytes;
    var initiator = try rotation.KeyRotation.init(secret, .{});
    defer initiator.deinit();
    var responder = try rotation.KeyRotation.init(secret, .{});
    defer responder.deinit();
    try std.testing.expectEqual(rotation.KeyRotationControl{ .kind = .update, .epoch = 1 }, try initiator.initiate());
    try std.testing.expectEqual(rotation.KeyRotationControl{ .kind = .acknowledge, .epoch = 1 }, try responder.receive_update(.{ .kind = .update, .epoch = 1 }));
    try std.testing.expectError(error.AuthenticationDowngrade, components.validate_negotiated_security(.{ .authentication = .psk }, .none));
}

test "security parser fuzz corpus remains bounded" {
    const Authenticator = struct {
        fn sign(_: *anyopaque, _: []const u8, tag: *[fragmentation.fragment_authentication_tag_bytes]u8) fragmentation.MessageFragmentAuthError!void {
            tag.* = .{0} ** fragmentation.fragment_authentication_tag_bytes;
        }

        fn verify(_: *anyopaque, _: []const u8, _: *const [fragmentation.fragment_authentication_tag_bytes]u8) fragmentation.MessageFragmentAuthError!void {
            return error.AuthenticationFailed;
        }
    };
    var authenticator = Authenticator{};
    const fragmenter = try fragmentation.MessageFragmenter.init(64, .{ .context = &authenticator, .sign_fn = Authenticator.sign, .verify_fn = Authenticator.verify });
    const key = protection.PacketProtectionKey.init([_]u8{2} ** protection.packet_protection_key_bytes, [_]u8{4} ** protection.packet_protection_nonce_prefix_bytes);
    var protector = protection.PacketProtector.init(key);
    defer protector.deinit();
    var seed: u64 = 0x5d4e_3c2b_1a09_f876;
    var input: [96]u8 = undefined;
    var output: [96]u8 = undefined;
    var iteration: usize = 0;
    while (iteration < 256) : (iteration += 1) {
        seed *%= 6_364_136_223_846_793_005;
        seed +%= 1;
        const length: usize = @intCast(seed % (input.len + 1));
        for (input[0..length]) |*byte| {
            seed *%= 6_364_136_223_846_793_005;
            seed +%= 1;
            byte.* = @truncate(seed >> 32);
        }
        if (packet.decode_packet(input[0..length]) catch null) |decoded| try std.testing.expect(decoded.payload.len <= packet.max_packet_payload_bytes);
        if (protector.open(input[0..length], output[0..]) catch null) |opened| try std.testing.expect(opened.payload.len <= input.len);
        if (fragmenter.decode(input[0..length]) catch null) |fragment| try std.testing.expect(fragment.payload.len <= 34);
    }
}
