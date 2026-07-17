const std = @import("std");
const congestion = @import("congestion_controller.zig");

pub const max_message_fragments: usize = 64;
pub const message_fragment_header_bytes: usize = 14;
pub const fragment_authentication_tag_bytes: usize = 16;
pub const MessageFragmentAuthError = error{AuthenticationFailed};
pub const MessageFragmentError = MessageFragmentAuthError || error{ InvalidPayloadBudget, MessageTooLarge, FragmentOutOfRange, OutputTooSmall, MalformedFragment };

pub const FragmentAuthenticator = struct {
    context: *anyopaque,
    sign_fn: *const fn (*anyopaque, []const u8, *[fragment_authentication_tag_bytes]u8) MessageFragmentAuthError!void,
    verify_fn: *const fn (*anyopaque, []const u8, *const [fragment_authentication_tag_bytes]u8) MessageFragmentAuthError!void,

    pub fn sign(self: FragmentAuthenticator, authenticated: []const u8, tag: *[fragment_authentication_tag_bytes]u8) MessageFragmentAuthError!void {
        return self.sign_fn(self.context, authenticated, tag);
    }

    pub fn verify(self: FragmentAuthenticator, authenticated: []const u8, tag: *const [fragment_authentication_tag_bytes]u8) MessageFragmentAuthError!void {
        return self.verify_fn(self.context, authenticated, tag);
    }
};

pub const MessageFragment = struct {
    message_id: u64,
    index: u16,
    count: u16,
    payload: []const u8,
};

pub const MessageFragmenter = struct {
    payload_budget: usize,
    fragment_payload_budget: usize,
    authenticator: FragmentAuthenticator,

    pub fn init(payload_budget: usize, authenticator: FragmentAuthenticator) MessageFragmentError!MessageFragmenter {
        const overhead = message_fragment_header_bytes + fragment_authentication_tag_bytes;
        if (payload_budget <= overhead or payload_budget - overhead > std.math.maxInt(u16)) return error.InvalidPayloadBudget;
        return .{ .payload_budget = payload_budget, .fragment_payload_budget = payload_budget - overhead, .authenticator = authenticator };
    }

    pub fn fragment_count(self: MessageFragmenter, message: []const u8) MessageFragmentError!u16 {
        const count = if (message.len == 0) 1 else std.math.divCeil(usize, message.len, self.fragment_payload_budget) catch return error.MessageTooLarge;
        if (count > max_message_fragments) return error.MessageTooLarge;
        return @intCast(count);
    }

    pub fn fragment_at(self: MessageFragmenter, route: congestion.RouteId, sequence: u64, message: []const u8, index: u16, output: []u8) MessageFragmentError![]u8 {
        const count = try self.fragment_count(message);
        if (index >= count) return error.FragmentOutOfRange;
        const start = @as(usize, index) * self.fragment_payload_budget;
        const end = @min(start + self.fragment_payload_budget, message.len);
        const payload = message[start..end];
        const total = message_fragment_header_bytes + payload.len + fragment_authentication_tag_bytes;
        if (output.len < total) return error.OutputTooSmall;
        write_header(output[0..message_fragment_header_bytes], .{
            .message_id = derive_message_id(route, sequence),
            .index = index,
            .count = count,
            .payload = payload,
        });
        @memcpy(output[message_fragment_header_bytes .. message_fragment_header_bytes + payload.len], payload);
        const authenticated = output[0 .. message_fragment_header_bytes + payload.len];
        const tag: *[fragment_authentication_tag_bytes]u8 = @ptrCast(output[authenticated.len..].ptr);
        try self.authenticator.sign(authenticated, tag);
        return output[0..total];
    }

    pub fn decode(self: MessageFragmenter, input: []const u8) MessageFragmentError!MessageFragment {
        if (input.len < message_fragment_header_bytes + fragment_authentication_tag_bytes) return error.MalformedFragment;
        const payload_length: usize = std.mem.readInt(u16, input[12..14], .big);
        const total = std.math.add(usize, message_fragment_header_bytes + fragment_authentication_tag_bytes, payload_length) catch return error.MalformedFragment;
        if (input.len != total) return error.MalformedFragment;
        const fragment = MessageFragment{
            .message_id = std.mem.readInt(u64, input[0..8], .big),
            .index = std.mem.readInt(u16, input[8..10], .big),
            .count = std.mem.readInt(u16, input[10..12], .big),
            .payload = input[message_fragment_header_bytes .. message_fragment_header_bytes + payload_length],
        };
        if (fragment.message_id == 0 or fragment.count == 0 or fragment.count > max_message_fragments or fragment.index >= fragment.count or fragment.payload.len > self.fragment_payload_budget or (fragment.count > 1 and fragment.payload.len == 0) or (fragment.index + 1 < fragment.count and fragment.payload.len != self.fragment_payload_budget)) return error.MalformedFragment;
        const tag: *const [fragment_authentication_tag_bytes]u8 = @ptrCast(input[input.len - fragment_authentication_tag_bytes ..].ptr);
        try self.authenticator.verify(input[0 .. input.len - fragment_authentication_tag_bytes], tag);
        return fragment;
    }
};

pub fn derive_message_id(route: congestion.RouteId, sequence: u64) u64 {
    var value = route ^ (sequence *% 0x9e37_79b9_7f4a_7c15);
    value ^= value >> 30;
    value *%= 0xbf58_476d_1ce4_e5b9;
    value ^= value >> 27;
    value *%= 0x94d0_49bb_1331_11eb;
    return (value ^ (value >> 31)) | 1;
}

fn write_header(output: []u8, fragment: MessageFragment) void {
    std.mem.writeInt(u64, output[0..8], fragment.message_id, .big);
    std.mem.writeInt(u16, output[8..10], fragment.index, .big);
    std.mem.writeInt(u16, output[10..12], fragment.count, .big);
    std.mem.writeInt(u16, output[12..14], @intCast(fragment.payload.len), .big);
}

test "authenticated message fragments are deterministic bounded and verifiable" {
    const Authenticator = struct {
        fn authenticator(self: *@This()) FragmentAuthenticator {
            return .{ .context = self, .sign_fn = sign, .verify_fn = verify };
        }

        fn sign(_: *anyopaque, authenticated: []const u8, tag: *[fragment_authentication_tag_bytes]u8) MessageFragmentAuthError!void {
            tag.* = .{0} ** fragment_authentication_tag_bytes;
            for (authenticated, 0..) |byte, index| tag[index % fragment_authentication_tag_bytes] +%= byte;
        }

        fn verify(context: *anyopaque, authenticated: []const u8, tag: *const [fragment_authentication_tag_bytes]u8) MessageFragmentAuthError!void {
            var expected: [fragment_authentication_tag_bytes]u8 = undefined;
            try sign(context, authenticated, &expected);
            if (!std.mem.eql(u8, &expected, tag)) return error.AuthenticationFailed;
        }
    };
    var auth = Authenticator{};
    const fragmenter = try MessageFragmenter.init(50, auth.authenticator());
    const message = "abcdefghijklmnopqrstuvwxyz1234567890abcdefgh";
    try std.testing.expectEqual(@as(u16, 3), try fragmenter.fragment_count(message));
    const first_id = derive_message_id(7, 11);
    try std.testing.expectEqual(first_id, derive_message_id(7, 11));
    try std.testing.expect(first_id != derive_message_id(8, 11));
    var encoded: [50]u8 = undefined;
    const wire = try fragmenter.fragment_at(7, 11, message, 1, encoded[0..]);
    const decoded = try fragmenter.decode(wire);
    try std.testing.expectEqual(first_id, decoded.message_id);
    try std.testing.expectEqual(@as(u16, 1), decoded.index);
    try std.testing.expectEqualStrings(message[20..40], decoded.payload);
    encoded[0] +%= 1;
    try std.testing.expectError(error.AuthenticationFailed, fragmenter.decode(wire));
}

test "message fragments reject bounds and malformed authenticated input" {
    const Authenticator = struct {
        fn authenticator(self: *@This()) FragmentAuthenticator {
            return .{ .context = self, .sign_fn = sign, .verify_fn = verify };
        }

        fn sign(_: *anyopaque, _: []const u8, tag: *[fragment_authentication_tag_bytes]u8) MessageFragmentAuthError!void {
            tag.* = .{0} ** fragment_authentication_tag_bytes;
        }

        fn verify(_: *anyopaque, _: []const u8, tag: *const [fragment_authentication_tag_bytes]u8) MessageFragmentAuthError!void {
            const expected = [_]u8{0} ** fragment_authentication_tag_bytes;
            if (!std.mem.eql(u8, &expected, tag)) return error.AuthenticationFailed;
        }
    };
    var auth = Authenticator{};
    try std.testing.expectError(error.InvalidPayloadBudget, MessageFragmenter.init(message_fragment_header_bytes + fragment_authentication_tag_bytes, auth.authenticator()));
    const fragmenter = try MessageFragmenter.init(31, auth.authenticator());
    const oversized = [_]u8{0} ** (max_message_fragments + 1);
    try std.testing.expectError(error.MessageTooLarge, fragmenter.fragment_count(&oversized));
    var output: [31]u8 = undefined;
    try std.testing.expectError(error.FragmentOutOfRange, fragmenter.fragment_at(1, 1, "a", 1, output[0..]));
    var short_output: [30]u8 = undefined;
    try std.testing.expectError(error.OutputTooSmall, fragmenter.fragment_at(1, 1, "a", 0, short_output[0..]));
    const malformed = [_]u8{0} ** (message_fragment_header_bytes + fragment_authentication_tag_bytes - 1);
    try std.testing.expectError(error.MalformedFragment, fragmenter.decode(malformed[0..]));
}
