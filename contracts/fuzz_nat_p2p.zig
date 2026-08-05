const std = @import("std");
const protocol = @import("minna-san-protocol");
const topology = @import("minna-san-topology");

fn candidate(expires_at_ns: u64) topology.NatCandidate {
    return .{ .kind = .host, .transport = .udp, .address = .{ .ipv4 = .{ .octets = .{ 127, 0, 0, 1 }, .port = 3478 } }, .priority = 1, .expires_at_ns = expires_at_ns };
}

test "bounded NAT P2P fuzz corpus rejects malformed signaling STUN TURN and check states" {
    var identity = try protocol.PublicKeyIdentity.init([_]u8{9} ** std.crypto.sign.Ed25519.KeyPair.seed_length);
    defer identity.clear();
    const credentials = protocol.SignalingApplicationCredentials{ .application_id = 3, .identity = identity };
    const verifier = protocol.SignalingVerificationConfig{ .application_id = 3, .session_intent = 4, .expected_signer_identity = try identity.public_key() };
    var replay_entries: [4]protocol.SignalingReplayEntry = undefined;
    var replay = protocol.SignedSignalingReplayRegistry.init(&replay_entries);
    var wire: [protocol.signed_signaling_header_bytes + 17 + protocol.signed_signaling_signature_bytes]u8 = undefined;
    const valid = try protocol.encode_signed_signaling_message(credentials, .{ .kind = .candidate, .session_intent = 4, .expires_at_ns = 1000, .nonce = 1, .payload = "candidate-fixture" }, &wire);
    var prng = std.Random.DefaultPrng.init(0x4f5b_94a1_5e72_3c19);
    const random = prng.random();
    var input: [256]u8 = undefined;
    var attributes: [4]protocol.StunAttribute = undefined;
    var channels = try topology.TurnChannels.init(std.testing.allocator, .{ .maximum_channels = 1 });
    defer channels.deinit();
    try channels.bind(.{ .number = topology.turn_channel_min, .peer = .{ .ipv4 = .{ .octets = .{ 127, 0, 0, 1 }, .port = 3478 } } });
    var scheduler = try topology.CandidatePairScheduler.init(std.testing.allocator, .{ .maximum_pairs = 2, .maximum_in_flight = 1, .maximum_attempts = 2, .pace_interval_ns = 1, .retry_interval_ns = 1, .check_timeout_ns = 1 });
    defer scheduler.deinit();
    _ = try scheduler.add(candidate(1000), candidate(1000), 2, 0);
    _ = try scheduler.add(candidate(1000), candidate(1000), 1, 0);
    var iteration: usize = 0;
    while (iteration < 512) : (iteration += 1) {
        const length = random.uintLessThan(usize, input.len + 1);
        random.bytes(input[0..length]);
        _ = replay.verify_and_remember(verifier, input[0..length], random.uintLessThan(u64, 1001)) catch {};
        _ = protocol.decode_stun_message(input[0..length], attributes[0..]) catch {};
        _ = channels.decode(input[0..length]) catch {};
        switch (random.uintLessThan(u3, 5)) {
            0 => _ = scheduler.dispatch(random.uintLessThan(u64, 1001)) catch {},
            1 => _ = scheduler.complete(random.uintLessThan(usize, 3), random.uintLessThan(u8, 2) != 0, random.uintLessThan(u64, 1001)) catch {},
            2 => _ = scheduler.cancel(random.uintLessThan(usize, 3)) catch {},
            3 => _ = scheduler.expire(random.uintLessThan(u64, 1001)) catch {},
            4 => {
                var diagnostics: [2]topology.CandidateCheckDiagnostic = undefined;
                _ = scheduler.diagnostics(diagnostics[0..]) catch {};
            },
            else => unreachable,
        }
        try std.testing.expect(replay.len <= replay_entries.len);
        try std.testing.expect(scheduler.pairs.items.len <= scheduler.config.maximum_pairs);
        try std.testing.expect(channels.count() <= 1);
    }
    _ = try replay.verify_and_remember(verifier, valid, 1);
    try std.testing.expectError(error.ReplayDetected, replay.verify_and_remember(verifier, valid, 1));
}
