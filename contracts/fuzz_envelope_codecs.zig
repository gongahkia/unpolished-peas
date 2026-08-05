const std = @import("std");
const protocol = @import("minna-san-protocol");

test "bounded envelope and codec fuzz corpus preserves parser limits" {
    const Authenticator = struct {
        fn sign(_: *anyopaque, _: []const u8, tag: *[protocol.fragment_authentication_tag_bytes]u8) protocol.MessageFragmentAuthError!void {
            tag.* = .{0} ** protocol.fragment_authentication_tag_bytes;
        }

        fn verify(_: *anyopaque, _: []const u8, _: *const [protocol.fragment_authentication_tag_bytes]u8) protocol.MessageFragmentAuthError!void {}
    };
    var authenticator = Authenticator{};
    const fragmenter = try protocol.MessageFragmenter.init(64, .{ .context = &authenticator, .sign_fn = Authenticator.sign, .verify_fn = Authenticator.verify });
    var random = std.Random.DefaultPrng.init(0xe26d_7015_2a83_4ff1);
    var input: [96]u8 = undefined;
    var iteration: usize = 0;
    while (iteration < 1_024) : (iteration += 1) {
        const source = random.random();
        const length = source.uintLessThan(usize, input.len + 1);
        source.bytes(input[0..length]);
        const bytes = input[0..length];
        if (protocol.decode_packet(bytes) catch null) |packet| {
            try std.testing.expect(packet.payload.len <= protocol.max_packet_payload_bytes);
            try protocol.validate_envelope(packet);
        }
        _ = protocol.handle_extension(source.int(u16), &.{}) catch {};
        var attributes: [4]protocol.StunAttribute = undefined;
        if (protocol.decode_stun_message(bytes, attributes[0..]) catch null) |message| try std.testing.expect(message.count <= attributes.len);
        _ = protocol.decode_xor_address(bytes, .{0} ** 12) catch {};
        _ = protocol.decode_error_code(bytes) catch {};
        if (protocol.decode_compression_frame(bytes) catch null) |frame| try std.testing.expect(frame.payload.len <= bytes.len -| protocol.compression_header_bytes);
        if (fragmenter.decode(bytes) catch null) |fragment| {
            try std.testing.expect(fragment.payload.len <= 34);
            var storage: [64]u8 = undefined;
            var reassembler = try protocol.MessageReassembler.init(.{ .maximum_message_bytes = 64, .fragment_payload_bytes = 34, .expiry_ns = 1, .maximum_inflight_messages = 1 }, storage[0..]);
            _ = reassembler.accept(fragment, @intCast(iteration)) catch {};
        }
    }
}

test "fuzz targets retain valid parser behavior and reject malformed frames" {
    var packet_storage: [protocol.packet_header_bytes + 1]u8 = undefined;
    const packet = try protocol.encode_packet(.{ .version = protocol.v1_version, .extension_id = 0, .payload = "x" }, packet_storage[0..]);
    try std.testing.expectEqualStrings("x", (try protocol.decode_packet(packet)).payload);
    var malformed = [_]u8{0} ** (protocol.compression_header_bytes - 1);
    try std.testing.expectError(error.MalformedFrame, protocol.decode_compression_frame(malformed[0..]));
}
