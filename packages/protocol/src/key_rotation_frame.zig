const std = @import("std");
const rotation = @import("key_rotation.zig");

pub const protected_datagram_payload_tag_bytes: usize = 1;
pub const key_rotation_control_frame_bytes: usize = protected_datagram_payload_tag_bytes + 1 + @sizeOf(rotation.KeyEpoch);
pub const KeyRotationFrameError = error{ OutputTooSmall, MalformedFrame };

pub const ProtectedDatagramPayloadKind = enum(u8) { application = 0, key_rotation = 1 };

pub const ProtectedDatagramPayload = union(ProtectedDatagramPayloadKind) {
    application: []const u8,
    key_rotation: rotation.KeyRotationControl,
};

pub fn encode_protected_datagram_application(payload: []const u8, output: []u8) KeyRotationFrameError![]u8 {
    if (output.len <= payload.len) return error.OutputTooSmall;
    output[0] = @intFromEnum(ProtectedDatagramPayloadKind.application);
    @memcpy(output[protected_datagram_payload_tag_bytes..][0..payload.len], payload);
    return output[0 .. protected_datagram_payload_tag_bytes + payload.len];
}

pub fn encode_key_rotation_control(control: rotation.KeyRotationControl, output: []u8) KeyRotationFrameError![]u8 {
    if (output.len < key_rotation_control_frame_bytes) return error.OutputTooSmall;
    output[0] = @intFromEnum(ProtectedDatagramPayloadKind.key_rotation);
    output[1] = @intFromEnum(control.kind);
    std.mem.writeInt(rotation.KeyEpoch, output[2..key_rotation_control_frame_bytes], control.epoch, .big);
    return output[0..key_rotation_control_frame_bytes];
}

pub fn decode_protected_datagram_payload(input: []const u8) KeyRotationFrameError!ProtectedDatagramPayload {
    if (input.len < protected_datagram_payload_tag_bytes) return error.MalformedFrame;
    const kind: ProtectedDatagramPayloadKind = std.meta.intToEnum(ProtectedDatagramPayloadKind, input[0]) catch return error.MalformedFrame;
    return switch (kind) {
        .application => .{ .application = input[protected_datagram_payload_tag_bytes..] },
        .key_rotation => .{ .key_rotation = try decode_key_rotation_control(input) },
    };
}

fn decode_key_rotation_control(input: []const u8) KeyRotationFrameError!rotation.KeyRotationControl {
    if (input.len != key_rotation_control_frame_bytes) return error.MalformedFrame;
    const kind = std.meta.intToEnum(rotation.KeyRotationControlKind, input[1]) catch return error.MalformedFrame;
    const epoch: *const [@sizeOf(rotation.KeyEpoch)]u8 = @ptrCast(input[2..].ptr);
    return .{ .kind = kind, .epoch = std.mem.readInt(rotation.KeyEpoch, epoch, .big) };
}

test "key rotation controls and application payloads are bounded and round trip" {
    var control_storage: [key_rotation_control_frame_bytes]u8 = undefined;
    const control = rotation.KeyRotationControl{ .kind = .update, .epoch = 4 };
    try std.testing.expectEqual(ProtectedDatagramPayload{ .key_rotation = control }, try decode_protected_datagram_payload(try encode_key_rotation_control(control, control_storage[0..])));
    var application_storage: [protected_datagram_payload_tag_bytes + 3]u8 = undefined;
    const application = try decode_protected_datagram_payload(try encode_protected_datagram_application("app", application_storage[0..]));
    try std.testing.expectEqualStrings("app", application.application);
    try std.testing.expectError(error.MalformedFrame, decode_protected_datagram_payload(&.{2}));
}
