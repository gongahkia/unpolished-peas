const std = @import("std");
const protection = @import("packet_protection.zig");

const hkdf = std.crypto.kdf.hkdf.HkdfSha256;
const next_secret_domain = "minna-san/v1/key-epoch-secret";
const packet_key_domain = "minna-san/v1/key-epoch-packet";

pub const KeyEpoch = u32;
pub const max_key_rotation_overlap_packets: usize = 64;
pub const KeyRotationError = error{ InvalidConfiguration, EpochExhausted, RotationPending, UnexpectedEpoch, NoPendingRotation, UnknownEpoch };
pub const KeyRotationControlKind = enum { update, acknowledge, rollback };

pub const KeyRotationConfig = struct {
    overlap_packets: usize = max_key_rotation_overlap_packets,
};

pub const KeyRotationControl = struct {
    kind: KeyRotationControlKind,
    epoch: KeyEpoch,
};

pub const RotatingPacketKey = struct {
    epoch: KeyEpoch,
    key: protection.PacketProtectionKey,

    pub fn clear(self: *RotatingPacketKey) void {
        self.key.clear();
    }
};

const EpochState = struct {
    epoch: KeyEpoch,
    secret: [protection.packet_protection_key_bytes]u8,
    key: protection.PacketProtectionKey,

    fn clear(self: *EpochState) void {
        std.crypto.secureZero(u8, &self.secret);
        self.key.clear();
    }
};

pub const KeyRotation = struct {
    config: KeyRotationConfig,
    current: EpochState,
    previous: ?EpochState = null,
    previous_receive_remaining: usize = 0,
    pending_ack: ?KeyEpoch = null,

    pub fn init(initial_secret: [protection.packet_protection_key_bytes]u8, config: KeyRotationConfig) KeyRotationError!KeyRotation {
        if (config.overlap_packets > max_key_rotation_overlap_packets) return error.InvalidConfiguration;
        return .{ .config = config, .current = derive_epoch_state(initial_secret, 0) };
    }

    pub fn deinit(self: *KeyRotation) void {
        self.current.clear();
        if (self.previous) |*previous| previous.clear();
        self.previous = null;
        self.previous_receive_remaining = 0;
        self.pending_ack = null;
    }

    pub fn current_epoch(self: KeyRotation) KeyEpoch {
        return self.current.epoch;
    }

    pub fn current_key(self: KeyRotation) RotatingPacketKey {
        return .{ .epoch = self.current.epoch, .key = self.current.key };
    }

    pub fn receive_key(self: *KeyRotation, epoch: KeyEpoch) KeyRotationError!RotatingPacketKey {
        if (epoch == self.current.epoch) return self.current_key();
        const previous = self.previous orelse return error.UnknownEpoch;
        if (epoch != previous.epoch or self.previous_receive_remaining == 0) return error.UnknownEpoch;
        return .{ .epoch = previous.epoch, .key = previous.key };
    }

    pub fn confirm_received(self: *KeyRotation, epoch: KeyEpoch) KeyRotationError!void {
        if (epoch == self.current.epoch) return;
        const previous = self.previous orelse return error.UnknownEpoch;
        if (epoch != previous.epoch or self.previous_receive_remaining == 0) return error.UnknownEpoch;
        self.previous_receive_remaining -= 1;
        self.discard_previous_if_retired();
    }

    pub fn initiate(self: *KeyRotation) KeyRotationError!KeyRotationControl {
        if (self.pending_ack != null) return error.RotationPending;
        const epoch = try next_epoch(self.current.epoch);
        self.rollover(epoch);
        self.pending_ack = epoch;
        return .{ .kind = .update, .epoch = epoch };
    }

    pub fn receive_update(self: *KeyRotation, update: KeyRotationControl) KeyRotationError!KeyRotationControl {
        if (update.kind != .update) return error.UnexpectedEpoch;
        if (update.epoch == self.current.epoch) return .{ .kind = .acknowledge, .epoch = update.epoch };
        if (self.pending_ack != null or update.epoch != try next_epoch(self.current.epoch)) return error.UnexpectedEpoch;
        self.rollover(update.epoch);
        return .{ .kind = .acknowledge, .epoch = update.epoch };
    }

    pub fn receive_acknowledgement(self: *KeyRotation, acknowledgement: KeyRotationControl) KeyRotationError!void {
        const pending = self.pending_ack orelse return error.NoPendingRotation;
        if (acknowledgement.kind != .acknowledge or acknowledgement.epoch != pending) return error.UnexpectedEpoch;
        self.pending_ack = null;
        self.discard_previous_if_retired();
    }

    pub fn recover_failed_rotation(self: *KeyRotation) KeyRotationError!KeyRotationControl {
        const pending = self.pending_ack orelse return error.NoPendingRotation;
        if (self.current.epoch != pending) return error.UnexpectedEpoch;
        const previous = self.previous orelse return error.UnexpectedEpoch;
        self.current.clear();
        self.current = previous;
        self.previous = null;
        self.previous_receive_remaining = 0;
        self.pending_ack = null;
        return .{ .kind = .rollback, .epoch = self.current.epoch };
    }

    pub fn receive_rollback(self: *KeyRotation, rollback: KeyRotationControl) KeyRotationError!void {
        if (rollback.kind != .rollback) return error.UnexpectedEpoch;
        if (rollback.epoch == self.current.epoch) return;
        const previous = self.previous orelse return error.UnexpectedEpoch;
        if (rollback.epoch != previous.epoch or self.current.epoch != try next_epoch(rollback.epoch)) return error.UnexpectedEpoch;
        self.current.clear();
        self.current = previous;
        self.previous = null;
        self.previous_receive_remaining = 0;
        self.pending_ack = null;
    }

    fn rollover(self: *KeyRotation, epoch: KeyEpoch) void {
        if (self.previous) |*previous| previous.clear();
        self.previous = self.current;
        self.previous_receive_remaining = self.config.overlap_packets;
        self.current = derive_epoch_state(next_secret(self.previous.?.secret, epoch), epoch);
    }

    fn discard_previous_if_retired(self: *KeyRotation) void {
        if (self.previous_receive_remaining != 0 or self.pending_ack != null) return;
        if (self.previous) |*previous| previous.clear();
        self.previous = null;
    }
};

fn next_epoch(epoch: KeyEpoch) KeyRotationError!KeyEpoch {
    if (epoch == std.math.maxInt(KeyEpoch)) return error.EpochExhausted;
    return epoch + 1;
}

fn next_secret(secret: [protection.packet_protection_key_bytes]u8, epoch: KeyEpoch) [protection.packet_protection_key_bytes]u8 {
    var output: [protection.packet_protection_key_bytes]u8 = undefined;
    const info = context(next_secret_domain, epoch);
    hkdf.expand(&output, &info, secret);
    return output;
}

fn derive_epoch_state(secret: [protection.packet_protection_key_bytes]u8, epoch: KeyEpoch) EpochState {
    var material: [protection.packet_protection_key_bytes + protection.packet_protection_nonce_prefix_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &material);
    const info = context(packet_key_domain, epoch);
    hkdf.expand(&material, &info, secret);
    return .{
        .epoch = epoch,
        .secret = secret,
        .key = protection.PacketProtectionKey.init(material[0..protection.packet_protection_key_bytes].*, material[protection.packet_protection_key_bytes..].*),
    };
}

fn context(comptime domain: []const u8, epoch: KeyEpoch) [domain.len + @sizeOf(KeyEpoch)]u8 {
    var value: [domain.len + @sizeOf(KeyEpoch)]u8 = undefined;
    @memcpy(value[0..domain.len], domain);
    std.mem.writeInt(KeyEpoch, value[domain.len..], epoch, .big);
    return value;
}

test "key rotation rolls keys forward and acknowledges the new epoch" {
    const secret = [_]u8{4} ** protection.packet_protection_key_bytes;
    var initiator = try KeyRotation.init(secret, .{ .overlap_packets = 2 });
    defer initiator.deinit();
    var responder = try KeyRotation.init(secret, .{ .overlap_packets = 2 });
    defer responder.deinit();
    const update = try initiator.initiate();
    try std.testing.expectEqual(KeyRotationControlKind.update, update.kind);
    try std.testing.expectEqual(@as(KeyEpoch, 1), update.epoch);
    const acknowledgement = try responder.receive_update(update);
    try initiator.receive_acknowledgement(acknowledgement);
    try std.testing.expectEqual(@as(KeyEpoch, 1), initiator.current_epoch());
    try std.testing.expectEqual(@as(KeyEpoch, 1), responder.current_epoch());
    var sender_key = initiator.current_key();
    defer sender_key.clear();
    var receiver_key = responder.current_key();
    defer receiver_key.clear();
    var sender = protection.PacketProtector.init(sender_key.key);
    defer sender.deinit();
    var receiver = protection.PacketProtector.init(receiver_key.key);
    defer receiver.deinit();
    var frame: [protection.packet_protection_frame_header_bytes + 1 + protection.packet_protection_tag_bytes]u8 = undefined;
    const sealed = try sender.seal("x", frame[0..]);
    var output: [1]u8 = undefined;
    try std.testing.expectEqualStrings("x", (try receiver.open(sealed, output[0..])).payload);
}

test "key rotation retains only a bounded previous receive epoch" {
    const secret = [_]u8{5} ** protection.packet_protection_key_bytes;
    var rotation = try KeyRotation.init(secret, .{ .overlap_packets = 1 });
    defer rotation.deinit();
    _ = try rotation.initiate();
    var old_key = try rotation.receive_key(0);
    defer old_key.clear();
    try rotation.confirm_received(0);
    try std.testing.expectError(error.UnknownEpoch, rotation.receive_key(0));
    try std.testing.expectError(error.RotationPending, rotation.initiate());
}

test "key rotation recovers failed rollover and rejects invalid controls" {
    const secret = [_]u8{6} ** protection.packet_protection_key_bytes;
    var initiator = try KeyRotation.init(secret, .{});
    defer initiator.deinit();
    var responder = try KeyRotation.init(secret, .{});
    defer responder.deinit();
    const update = try initiator.initiate();
    _ = try responder.receive_update(update);
    const rollback = try initiator.recover_failed_rotation();
    try responder.receive_rollback(rollback);
    try std.testing.expectEqual(@as(KeyEpoch, 0), initiator.current_epoch());
    try std.testing.expectEqual(@as(KeyEpoch, 0), responder.current_epoch());
    try std.testing.expectError(error.NoPendingRotation, initiator.receive_acknowledgement(.{ .kind = .acknowledge, .epoch = 1 }));
    try std.testing.expectError(error.UnexpectedEpoch, responder.receive_update(.{ .kind = .update, .epoch = 3 }));
}
