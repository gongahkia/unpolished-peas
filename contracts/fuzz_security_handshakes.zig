const std = @import("std");
const protocol = @import("minna-san-protocol");

fn offer(random: std.Random) protocol.CapabilityOffer {
    return .{
        .transports = random.int(u8),
        .channels = random.int(u8),
        .security = random.int(u8),
        .compression = random.int(u8),
        .extensions = random.int(u64),
    };
}

fn security(random: std.Random) protocol.SecurityCapability {
    return switch (random.uintLessThan(u8, 3)) {
        0 => .none,
        1 => .psk,
        2 => .public_key,
        else => unreachable,
    };
}

fn control_kind(random: std.Random) protocol.KeyRotationControlKind {
    return switch (random.uintLessThan(u8, 3)) {
        0 => .update,
        1 => .acknowledge,
        2 => .rollback,
        else => unreachable,
    };
}

test "bounded negotiation and security fuzz corpus preserves transition limits" {
    var random = std.Random.DefaultPrng.init(0x7c9a_124b_9e08_5d21);
    var input: [96]u8 = undefined;
    var output: [96]u8 = undefined;
    var iteration: usize = 0;
    while (iteration < 128) : (iteration += 1) {
        const source = random.random();
        _ = protocol.negotiate_capabilities(offer(source), offer(source)) catch {};
        const components = protocol.SecurityComponents{
            .authentication = security(source),
            .authenticated_encryption = source.uintLessThan(u8, 2) != 0,
            .replay_protection = source.uintLessThan(u8, 2) != 0,
            .key_rotation = source.uintLessThan(u8, 2) != 0,
        };
        _ = protocol.validate_security_components(components) catch {};
        _ = protocol.validate_negotiated_security(components, security(source)) catch {};

        var material: [protocol.min_psk_bytes]u8 = undefined;
        var nonce: [protocol.psk_challenge_nonce_bytes]u8 = undefined;
        source.bytes(&material);
        source.bytes(&nonce);
        var client = try protocol.PskAuthenticator.init(material[0..]);
        var server = try protocol.PskAuthenticator.init(material[0..]);
        const challenge = protocol.PskChallenge{ .session_id = source.int(u64), .nonce = nonce };
        try server.begin(challenge);
        var proof = client.prove(challenge);
        if (source.uintLessThan(u8, 2) != 0) proof.tag[source.uintLessThan(usize, proof.tag.len)] +%= 1;
        _ = server.verify_pending(proof) catch {};
        client.deinit();
        server.deinit();

        var initiator_seed: [std.crypto.sign.Ed25519.KeyPair.seed_length]u8 = undefined;
        var responder_seed: [std.crypto.sign.Ed25519.KeyPair.seed_length]u8 = undefined;
        source.bytes(&initiator_seed);
        source.bytes(&responder_seed);
        const initiator_identity = try protocol.PublicKeyIdentity.init(initiator_seed);
        const responder_identity = try protocol.PublicKeyIdentity.init(responder_seed);
        const expected_responder = try responder_identity.public_key();
        var initiator = protocol.PublicKeyKeyExchange.init(initiator_identity, source.int(u64), .initiator);
        var responder = protocol.PublicKeyKeyExchange.init(responder_identity, initiator.session_id, .responder);
        var hello = try responder.hello();
        if (source.uintLessThan(u8, 2) != 0) hello.signature[source.uintLessThan(usize, hello.signature.len)] +%= 1;
        _ = initiator.derive_session_key(expected_responder, hello) catch {};
        initiator.deinit();
        responder.deinit();

        var key: [protocol.packet_protection_key_bytes]u8 = undefined;
        var prefix: [protocol.packet_protection_nonce_prefix_bytes]u8 = undefined;
        source.bytes(&key);
        source.bytes(&prefix);
        var protector = protocol.PacketProtector.init(.init(key, prefix));
        const length = source.uintLessThan(usize, input.len + 1);
        source.bytes(input[0..length]);
        _ = protector.open(input[0..length], output[0..]) catch {};
        protector.deinit();
        var replay = try protocol.ReplayWindow.init(.{ .window_size = source.uintLessThan(usize, protocol.max_replay_window_packets) + 1 });
        _ = replay.observe(source.int(u64));
        _ = replay.observe(source.int(u64));

        var secret: [protocol.packet_protection_key_bytes]u8 = undefined;
        source.bytes(&secret);
        var rotation = try protocol.KeyRotation.init(secret, .{ .overlap_packets = source.uintLessThan(usize, protocol.max_key_rotation_overlap_packets + 1) });
        const control = protocol.KeyRotationControl{ .kind = control_kind(source), .epoch = source.int(protocol.KeyEpoch) };
        _ = rotation.receive_update(control) catch {};
        _ = rotation.receive_acknowledgement(control) catch {};
        _ = rotation.receive_rollback(control) catch {};
        if (rotation.initiate() catch null) |update| _ = rotation.receive_acknowledgement(.{ .kind = .acknowledge, .epoch = update.epoch }) catch {};
        rotation.deinit();
    }
}

test "security fuzz targets retain valid negotiated and authenticated handshakes" {
    const capabilities = protocol.CapabilityOffer{ .transports = 1, .channels = 1, .security = 1, .compression = 1, .extensions = 0 };
    try std.testing.expectEqual(protocol.SecurityCapability.none, (try protocol.negotiate_capabilities(capabilities, capabilities)).security);
    const material = [_]u8{7} ** protocol.min_psk_bytes;
    var client = try protocol.PskAuthenticator.init(material[0..]);
    defer client.deinit();
    var server = try protocol.PskAuthenticator.init(material[0..]);
    defer server.deinit();
    const challenge = protocol.PskChallenge{ .session_id = 1, .nonce = .{3} ** protocol.psk_challenge_nonce_bytes };
    try server.begin(challenge);
    try server.verify_pending(client.prove(challenge));
    const secret = [_]u8{4} ** protocol.packet_protection_key_bytes;
    var initiator = try protocol.KeyRotation.init(secret, .{});
    defer initiator.deinit();
    var responder = try protocol.KeyRotation.init(secret, .{});
    defer responder.deinit();
    const update = try initiator.initiate();
    try initiator.receive_acknowledgement(try responder.receive_update(update));
    try std.testing.expectEqual(initiator.current_epoch(), responder.current_epoch());
}
