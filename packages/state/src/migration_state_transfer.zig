const std = @import("std");
const migration = @import("migration_coordinator.zig");

const hmac = std.crypto.auth.hmac.sha2.HmacSha256;
const sha256 = std.crypto.hash.sha2.Sha256;

pub const migration_transfer_integrity_tag_bytes: usize = hmac.mac_length;
pub const MigrationStateMetadata = struct {
    term: migration.MigrationTerm,
    source_host: migration.MigrationHostId,
    destination_host: migration.MigrationHostId,
    membership_revision: u64,
    state_revision: u64,
    route: migration.MigrationRoute,
};
pub const AcknowledgedMigrationSnapshot = struct {
    metadata: MigrationStateMetadata,
    state: []const u8,
    acknowledged: bool,
};
pub const MigrationStateTransferFrame = struct {
    metadata: MigrationStateMetadata,
    state: []const u8,
    integrity_tag: [migration_transfer_integrity_tag_bytes]u8,
};
pub const MigrationStateTransferError = error{ InvalidConfiguration, InvalidMetadata, SnapshotNotAcknowledged, StateTooLarge, IntegrityMismatch, WrongDestination };
pub const MigrationStateTransferConfig = struct {
    maximum_state_bytes: usize,
    integrity_key: [sha256.digest_length]u8,
};

pub const MigrationStateTransfer = struct {
    config: MigrationStateTransferConfig,

    pub fn init(config: MigrationStateTransferConfig) MigrationStateTransferError!MigrationStateTransfer {
        if (config.maximum_state_bytes == 0) return error.InvalidConfiguration;
        return .{ .config = config };
    }
    pub fn create(self: MigrationStateTransfer, snapshot: AcknowledgedMigrationSnapshot) MigrationStateTransferError!MigrationStateTransferFrame {
        try self.validate_snapshot(snapshot);
        return .{ .metadata = snapshot.metadata, .state = snapshot.state, .integrity_tag = self.integrity_tag(snapshot.metadata, snapshot.state) };
    }
    pub fn accept(self: MigrationStateTransfer, frame: MigrationStateTransferFrame, elected_host: migration.MigrationHostId) MigrationStateTransferError!AcknowledgedMigrationSnapshot {
        const snapshot = AcknowledgedMigrationSnapshot{ .metadata = frame.metadata, .state = frame.state, .acknowledged = true };
        try self.validate_snapshot(snapshot);
        const expected = self.integrity_tag(frame.metadata, frame.state);
        if (!std.crypto.timing_safe.eql([migration_transfer_integrity_tag_bytes]u8, expected, frame.integrity_tag)) return error.IntegrityMismatch;
        if (frame.metadata.destination_host != elected_host) return error.WrongDestination;
        return snapshot;
    }
    fn validate_snapshot(self: MigrationStateTransfer, snapshot: AcknowledgedMigrationSnapshot) MigrationStateTransferError!void {
        if (!snapshot.acknowledged) return error.SnapshotNotAcknowledged;
        if (snapshot.state.len > self.config.maximum_state_bytes) return error.StateTooLarge;
        const value = snapshot.metadata;
        if (value.term == 0 or value.source_host == 0 or value.destination_host == 0 or value.source_host == value.destination_host) return error.InvalidMetadata;
    }
    fn integrity_tag(self: MigrationStateTransfer, value: MigrationStateMetadata, state: []const u8) [migration_transfer_integrity_tag_bytes]u8 {
        var signer = hmac.init(&self.config.integrity_key);
        var encoded: [8]u8 = undefined;
        std.mem.writeInt(u64, encoded[0..], value.term, .big);
        signer.update(&encoded);
        std.mem.writeInt(u64, encoded[0..], value.source_host, .big);
        signer.update(&encoded);
        std.mem.writeInt(u64, encoded[0..], value.destination_host, .big);
        signer.update(&encoded);
        std.mem.writeInt(u64, encoded[0..], value.membership_revision, .big);
        signer.update(&encoded);
        std.mem.writeInt(u64, encoded[0..], value.state_revision, .big);
        signer.update(&encoded);
        const route = [_]u8{@intFromEnum(value.route)};
        signer.update(&route);
        signer.update(state);
        var tag: [migration_transfer_integrity_tag_bytes]u8 = undefined;
        signer.final(&tag);
        return tag;
    }
};

fn test_metadata() MigrationStateMetadata {
    return .{ .term = 2, .source_host = 1, .destination_host = 4, .membership_revision = 8, .state_revision = 9, .route = .relay };
}

test "migration state transfer authenticates acknowledged snapshots and metadata for the elected host" {
    const transfer = try MigrationStateTransfer.init(.{ .maximum_state_bytes = 8, .integrity_key = [_]u8{7} ** sha256.digest_length });
    const frame = try transfer.create(.{ .metadata = test_metadata(), .state = "state", .acknowledged = true });
    const restored = try transfer.accept(frame, 4);
    try std.testing.expect(restored.acknowledged);
    try std.testing.expectEqual(test_metadata(), restored.metadata);
    try std.testing.expectEqualStrings("state", restored.state);
}

test "migration state transfer rejects unacknowledged oversized tampered and wrong-host frames" {
    const transfer = try MigrationStateTransfer.init(.{ .maximum_state_bytes = 4, .integrity_key = [_]u8{9} ** sha256.digest_length });
    try std.testing.expectError(error.SnapshotNotAcknowledged, transfer.create(.{ .metadata = test_metadata(), .state = "ok", .acknowledged = false }));
    try std.testing.expectError(error.StateTooLarge, transfer.create(.{ .metadata = test_metadata(), .state = "large", .acknowledged = true }));
    var frame = try transfer.create(.{ .metadata = test_metadata(), .state = "ok", .acknowledged = true });
    frame.integrity_tag[0] +%= 1;
    try std.testing.expectError(error.IntegrityMismatch, transfer.accept(frame, 4));
    frame = try transfer.create(.{ .metadata = test_metadata(), .state = "ok", .acknowledged = true });
    try std.testing.expectError(error.WrongDestination, transfer.accept(frame, 3));
    try std.testing.expectError(error.InvalidConfiguration, MigrationStateTransfer.init(.{ .maximum_state_bytes = 0, .integrity_key = [_]u8{0} ** sha256.digest_length }));
}
